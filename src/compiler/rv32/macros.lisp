;;;; various useful macros for generating RV32 code

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;; Instruction-like macros.

(defmacro move (dst src)
  "Move SRC into DST (unless they are location=."
  (once-only ((n-dst dst)
              (n-src src))
    `(unless (location= ,n-dst ,n-src)
       (inst addi ,n-dst ,n-src 0))))

(macrolet ((def-mem-op (op inst shift)
             `(defmacro ,op (object base &optional (offset 0) (lowtag 0))
                `(inst ,',inst ,object ,base (- (ash ,offset ,,shift) ,lowtag)))))
  (def-mem-op loadw #-64-bit lw #+64-bit ld word-shift)
  (def-mem-op storew #-64-bit sw #+64-bit sd word-shift))

(defmacro load-symbol (reg symbol)
  `(inst addi ,reg null-tn (static-symbol-offset ,symbol)))

(defmacro load-symbol-value (reg symbol)
  `(inst #-64-bit lw #+64-bit ld ,reg null-tn
         (+ (static-symbol-offset ',symbol)
            (ash symbol-value-slot word-shift)
            (- other-pointer-lowtag))))

(defmacro store-symbol-value (reg symbol)
  `(inst #-64-bit sw #+64-bit sd ,reg null-tn
         (+ (static-symbol-offset ',symbol)
            (ash symbol-value-slot word-shift)
            (- other-pointer-lowtag))))

(defun load-foreign-symbol-value (dest symbol temp)
  (let ((fixup (make-fixup symbol :foreign)))
    (inst lui temp fixup)
    (inst #-64-bit lw #+64-bit ld dest temp fixup)))

(defun store-foreign-symbol-value (src symbol temp)
  (let ((fixup (make-fixup symbol :foreign)))
    (inst lui temp fixup)
    (inst #-64-bit sw #+64-bit sd src temp fixup)))

(defmacro load-type (target source &optional (offset 0))
  "Loads the type bits of a pointer into target independent of
byte-ordering issues."
  `(inst lbu ,target ,source ,offset))

(defun lisp-jump (function)
  "Jump to the lisp function FUNCTION."
  (inst jalr zero-tn function (- (ash simple-fun-code-offset word-shift)
                                 fun-pointer-lowtag)))

(defun lisp-return (return-pc return-style)
  "Return to RETURN-PC."
  (ecase return-style
    (:single-value (inst li nargs-tn -1))
    (:multiple-values)
    (:known))
  (inst jalr zero-tn return-pc (- other-pointer-lowtag)))

(defun emit-return-pc (label)
  "Emit a return-pc header word.  LABEL is the label to use for this return-pc."
  (emit-alignment n-lowtag-bits)
  (emit-label label)
  (inst lra-header-word))


;;;; Three Way Comparison
(defun three-way-comparison (x y condition flavor not-p target)
  (ecase condition
    (:eq (if not-p
             (inst bne x y target)
             (inst beq x y target)))
    ((:lt :gt)
     (when (eq flavor :gt)
       (rotatef x y))
     (ecase flavor
       (:unsigned (if not-p
                      (inst bltu x y target)
                      (inst bgeu x y target)))
       (:signed (if not-p
                    (inst blt x y target)
                    (inst bge x y target)))))))


(defun emit-error-break (vop kind code values)
  (assemble ()
    (when vop (note-this-location vop :internal-error))
    ;; Encode both kind and code as an argument to EBREAM
    (inst ebreak (dpb code (byte 8 8) kind))
    ;; NARGS is implicitely assumed for invalid-arg-count
    (unless (= kind invalid-arg-count-trap)
      (encode-internal-error-args values)
      (emit-alignment 2))))

(defun generate-error-code (vop error-code &rest values)
  "Generate-Error-Code Error-code Value*
  Emit code for an error with the specified Error-Code and context Values."
  (assemble (:elsewhere)
    (let ((start-lab (gen-label)))
      (emit-label start-lab)
      (emit-error-break vop error-trap (error-number-or-lose error-code) values)
      start-lab)))

;;;; PSEUDO-ATOMIC

;;; handy macro for making sequences look atomic
(defmacro pseudo-atomic ((flag-tn) &body forms)
  `(progn
     (without-scheduling ()
       (store-symbol-value csp-tn *pseudo-atomic-atomic*))
     (assemble ()
       ,@forms)
     (without-scheduling ()
       (store-symbol-value null-tn *pseudo-atomic-atomic*)
       (load-symbol-value ,flag-tn *pseudo-atomic-interrupted*)
       (let ((not-interrupted (gen-label)))
         (inst beq ,flag-tn zero-tn not-interrupted)
         (inst ebreak pending-interrupt-trap)
         (emit-label not-interrupted)))))

#|
If we are doing [reg+offset*n-word-bytes-lowtag+index*scale]
and

-2^11 ≤ offset*n-word-bytes - lowtag + index*scale < 2^11
-2^11 ≤ offset*n-word-bytes - lowtag + index*scale ≤ 2^11-1
-2^11 + lowtag -offset*n-word-bytes ≤ index*scale ≤ 2^11-1 + lowtag - offset*n-word-bytes
|#
(def!type load/store-index (scale lowtag offset)
  (let* ((encodable (list (- (ash 1 11)) (1- (ash 1 11))))
         (add-lowtag (mapcar (lambda (x) (+ x lowtag)) encodable))
         (sub-offset (mapcar (lambda (x) (- x (* offset n-word-bytes))) add-lowtag))
         (truncated (mapcar (lambda (x) (truncate x scale)) sub-offset)))
    `(integer ,(first truncated) ,(second truncated))))

(defmacro define-full-reffer (name type offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)) (index :scs (any-reg)))
       (:arg-types ,type tagged-num)
       (:temporary (:scs (interior-reg)) lip)
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 5
         (inst add lip object index)
         (loadw value lip ,offset ,lowtag)))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)))
       (:info index)
       (:arg-types ,type
         (:constant
         (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset))))
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 4
         (loadw value object (+ ,offset index) ,lowtag)))))

(defmacro define-full-setter (name type offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)) (index :scs (any-reg)) (value :scs ,scs))
       (:arg-types ,type tagged-num ,eltype)
       (:temporary (:scs (interior-reg)) lip)
       (:results (result :scs ,scs))
       (:result-types ,eltype)
       (:generator 3
         (inst add lip object index)
         (storew value lip ,offset ,lowtag)
         (move result value)))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate
           `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (value :scs ,scs))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset)))
         ,eltype)
       (:results (result :scs ,scs))
       (:result-types ,eltype)
       (:generator 1
         (storew value object (+ ,offset index) ,lowtag)
         (move result value)))))

(defmacro define-partial-reffer (name type size signed offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)) (index :scs (any-reg)))
       (:arg-types ,type positive-fixnum)
       (:temporary (:scs (interior-reg)) lip)
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 5
         (inst add lip object index)
         ,@(when (= size 1)
             '((inst add lip lip index)))
         (inst ,(ecase size
                  (1 (if signed 'lb 'lbu))
                  (2 (if signed 'lh 'lhu))
                  (4 (if signed 'lw 'lwu)))
               value lip (- (* ,offset n-word-bytes) ,lowtag))))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate
           `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset))))
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 4
         (inst ,(ecase size
                  (1 (if signed 'lb 'lbu))
                  (2 (if signed 'lh 'lhu))
                  (4 (if signed 'lw 'lwu)))
               value object
               (- (+ (* ,offset n-word-bytes) (* index ,size)) ,lowtag))))))

(defmacro define-partial-setter (name type size offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)) (index :scs (any-reg)) (value :scs ,scs))
       (:arg-types ,type positive-fixnum ,eltype)
       (:results (result :scs ,scs))
       (:temporary (:scs (interior-reg)) lip)
       (:result-types ,eltype)
       (:generator 5
         ,@(let ((shift size))
             (decf shift n-fixnum-tag-bits)
             (unless (zerop shift)
               (if (minusp shift)
                   `((inst srai index index ,shift))
                   `((inst slli index index ,shift)))))
         (inst add lip object index)
         (inst ,(ecase size (1 'sb) (2 'sh) (4 'sw))
               value lip (- (* ,offset n-word-bytes) ,lowtag))
         (move result value)))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate
           `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (value :scs ,scs :target result))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset)))
         ,eltype)
       (:results (result :scs ,scs))
       (:result-types ,eltype)
       (:generator 4
         (inst ,(ecase size (1 'sb) (2 'sh) (4 'sw))
               value object
               (- (+ (* ,offset n-word-bytes) (* index ,size)) ,lowtag))
         (move result value)))))


;;;; Stack TN's

;;; Move a stack TN to a register and vice-versa.
(defmacro load-stack-tn (reg stack)
  `(let ((reg ,reg)
         (stack ,stack))
     (let ((offset (tn-offset stack)))
       (sc-case stack
         ((control-stack)
          (loadw reg cfp-tn offset))))))

(defmacro store-stack-tn (stack reg)
  `(let ((stack ,stack)
         (reg ,reg))
     (let ((offset (tn-offset stack)))
       (sc-case stack
         ((control-stack)
          (storew reg cfp-tn offset))))))

(defmacro maybe-load-stack-tn (reg reg-or-stack)
  "Move the TN Reg-Or-Stack into Reg if it isn't already there."
  (once-only ((n-reg reg)
              (n-stack reg-or-stack))
    `(sc-case ,n-reg
       ((any-reg descriptor-reg)
        (sc-case ,n-stack
          ((any-reg descriptor-reg)
           (move ,n-reg ,n-stack))
          ((control-stack)
           (loadw ,n-reg cfp-tn (tn-offset ,n-stack))))))))


;;;; Storage allocation:
(defun allocation (result-tn size lowtag &key flag-tn
                                              stack-allocate-p)
  (declare (ignore stack-allocate-p))
  ;; Normal allocation to the heap.
  (load-symbol-value flag-tn *allocation-pointer*)
  (inst addi result-tn flag-tn lowtag)
  (etypecase size
    (short-immediate
     (inst addi flag-tn flag-tn size))
    ((signed-byte 32)
     (inst li flag-tn (- size lowtag))
     (inst add flag-tn flag-tn result-tn))
    (tn
     (inst add flag-tn flag-tn size)))
  (store-symbol-value flag-tn *allocation-pointer*))

(defmacro with-fixed-allocation ((result-tn flag-tn type-code size
                                  &key (lowtag other-pointer-lowtag)
                                       stack-allocate-p)
                                 &body body)
  "Do stuff to allocate an other-pointer object of fixed Size with a single
  word header having the specified Type-Code.  The result is placed in
  Result-TN, and Temp-TN is a non-descriptor temp (which may be randomly used
  by the body.)  The body is placed inside the PSEUDO-ATOMIC, and presumably
  initializes the object."
  (once-only ((result-tn result-tn) (flag-tn flag-tn)
              (type-code type-code) (size size)
              (lowtag lowtag))
    `(pseudo-atomic (,flag-tn)
       (allocation ,result-tn (pad-data-block ,size) ,lowtag
                   :flag-tn ,flag-tn
                   :stack-allocate-p ,stack-allocate-p)
       (when ,type-code
         (inst li ,flag-tn (+ (ash (1- ,size) n-widetag-bits) ,type-code))
         (storew ,flag-tn ,result-tn 0 ,lowtag))
       ,@body)))

(defun load-binding-stack-pointer (reg)
  (load-symbol-value reg *binding-stack-pointer*))

(defun store-binding-stack-pointer (reg)
  (store-symbol-value reg *binding-stack-pointer*))