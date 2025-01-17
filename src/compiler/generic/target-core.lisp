;;;; target-only code that knows how to load compiled code directly
;;;; into core
;;;;
;;;; FIXME: The filename here is confusing because "core" here means
;;;; "main memory", while elsewhere in the system it connotes a
;;;; ".core" file dumping the contents of main memory.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-C")

;;; Map of code-component -> list of PC offsets at which allocations occur.
;;; This table is needed in order to enable allocation profiling.
(define-load-time-global *allocation-point-fixups*
  (make-hash-table :test 'eq :weakness :key :synchronized t))

#-x86-64
(progn
(defun convert-alloc-point-fixups (dummy1 dummy2)
  (declare (ignore dummy1 dummy2)))
(defun sb-vm::statically-link-code-obj (code fixups)
  (declare (ignore code fixups))))

#+immobile-code
(progn
  ;; Use FDEFINITION because it strips encapsulations - whether that's
  ;; the right behavior for it or not is a separate concern.
  ;; If somebody tries (TRACE LENGTH) for example, it should not cause
  ;; compilations to fail on account of LENGTH becoming a closure.
  (defun sb-vm::function-raw-address (name &aux (fun (fdefinition name)))
    (cond ((not (immobile-space-obj-p fun))
           (error "Can't statically link to ~S: code is movable" name))
          ((neq (fun-subtype fun) sb-vm:simple-fun-widetag)
           (error "Can't statically link to ~S: non-simple function" name))
          (t
           (let ((addr (get-lisp-obj-address fun)))
             (sap-ref-word (int-sap addr)
                           (- (ash sb-vm:simple-fun-self-slot sb-vm:word-shift)
                              sb-vm:fun-pointer-lowtag))))))

  ;; Return the address to which to jump when calling FDEFN,
  ;; which is either an fdefn or the name of an fdefn.
  (defun sb-vm::fdefn-entry-address (fdefn)
    (let ((fdefn (if (fdefn-p fdefn) fdefn (find-or-create-fdefn fdefn))))
      (+ (get-lisp-obj-address fdefn)
         (- 2 sb-vm:other-pointer-lowtag)))))

;;; Point FUN's 'self' slot to FUN.
;;; FUN must be pinned when calling this.
(declaim (inline assign-simple-fun-self))
(defun assign-simple-fun-self (fun)
  (setf (%simple-fun-self fun)
        ;; x86 backends store the address of the entrypoint in 'self'
        #+(or x86 x86-64)
        (%make-lisp-obj
         (truly-the word (+ (get-lisp-obj-address fun)
                            (ash sb-vm:simple-fun-insts-offset sb-vm:word-shift)
                            (- sb-vm:fun-pointer-lowtag))))
        ;; non-x86 backends store the function itself (what else?) in 'self'
        #-(or x86 x86-64) fun))

(flet ((fixup (code-obj offset sym kind flavor preserved-lists statically-link-p)
         (declare (ignorable statically-link-p))
         ;; PRESERVED-LISTS is a vector of lists of locations (by kind)
         ;; at which fixup must be re-applied after code movement.
         ;; CODE-OBJ must already be pinned in order to legally call this.
         ;; One call site that reaches here is below at MAKE-CORE-COMPONENT
         ;; and the other is LOAD-CODE, both of which pin the code.
         (when (sb-vm:fixup-code-object
                 code-obj offset
                 (ecase flavor
                   ((:assembly-routine :assembly-routine* :asm-routine-nil-offset)
                    (- (or (get-asm-routine sym (eq flavor :assembly-routine*))
                           (error "undefined assembler routine: ~S" sym))
                       (if (eq flavor :asm-routine-nil-offset) sb-vm:nil-value 0)))
                   (:foreign (foreign-symbol-address sym))
                   (:foreign-dataref (foreign-symbol-address sym t))
                   (:code-object (get-lisp-obj-address code-obj))
                   #+sb-thread (:symbol-tls-index (ensure-symbol-tls-index sym))
                   (:layout (get-lisp-obj-address
                             (if (symbolp sym) (find-layout sym) sym)))
                   (:immobile-symbol (get-lisp-obj-address sym))
                   (:symbol-value (get-lisp-obj-address (symbol-global-value sym)))
                   #+immobile-code
                   (:named-call
                    (when statically-link-p
                      (push (cons offset sym) (elt preserved-lists 0)))
                    (sb-vm::fdefn-entry-address sym))
                   #+immobile-code (:static-call (sb-vm::function-raw-address sym)))
                 kind flavor)
           (ecase kind
             (:relative (push offset (elt preserved-lists 1)))
             (:absolute (push offset (elt preserved-lists 2)))
             (:absolute64 (push offset (elt preserved-lists 3)))))
         ;; These won't exist except for x86-64, but it doesn't matter.
         (when (member sym '(sb-vm::enable-alloc-counter
                             sb-vm::enable-sized-alloc-counter))
           (push offset (elt preserved-lists 4))))

       (finish-fixups (code-obj preserved-lists)
         (declare (ignorable code-obj preserved-lists))
         #+(or x86 x86-64)
         (let ((rel-fixups (elt preserved-lists 1))
               (abs-fixups (elt preserved-lists 2))
               (abs64-fixups (elt preserved-lists 3)))
           (aver (not abs64-fixups)) ; no preserved 64-bit fixups
           (when (or abs-fixups rel-fixups)
             (setf (sb-vm::%code-fixups code-obj)
                   (sb-c::pack-code-fixup-locs abs-fixups rel-fixups))))
         (awhen (elt preserved-lists 4)
           (setf (gethash code-obj *allocation-point-fixups*)
                 (convert-alloc-point-fixups code-obj it)))
         (awhen (aref preserved-lists 0)
           (sb-vm::statically-link-code-obj code-obj it))
         ;; Assign all SIMPLE-FUN-SELF slots
         (dotimes (i (code-n-entries code-obj))
           (let ((fun (%code-entry-point code-obj i)))
             (assign-simple-fun-self fun)
             ;; And maybe store the layout in the high half of the header
             #+(and compact-instance-header x86-64)
             (setf (sap-ref-32 (int-sap (get-lisp-obj-address fun))
                               (- 4 sb-vm:fun-pointer-lowtag))
                   (truly-the (unsigned-byte 32)
                     (get-lisp-obj-address #.(find-layout 'function))))))
         ;; And finally, make the memory range executable
         #-(or x86 x86-64)
         (sb-vm:sanctify-for-execution code-obj)))

  (defun apply-fasl-fixups (fop-stack code-obj n-fixups &aux (top (svref fop-stack 0)))
    (dx-let ((preserved (make-array 5 :initial-element nil)))
      (macrolet ((pop-fop-stack () `(prog1 (svref fop-stack top) (decf top))))
        (dotimes (i n-fixups (setf (svref fop-stack 0) top))
          (multiple-value-bind (offset kind flavor)
              (sb-fasl::!unpack-fixup-info (pop-fop-stack))
            (fixup code-obj offset (pop-fop-stack) kind flavor
                   preserved nil))))
      (finish-fixups code-obj preserved)))

  (defun apply-core-fixups (fixup-notes code-obj)
    (declare (list fixup-notes))
    (dx-let ((preserved (make-array 5 :initial-element nil)))
      (dolist (note fixup-notes)
        (let ((fixup (fixup-note-fixup note))
              (offset (fixup-note-position note)))
          (fixup code-obj offset
                 (fixup-name fixup)
                 (fixup-note-kind note)
                 (fixup-flavor fixup)
                 preserved t)))
      (finish-fixups code-obj preserved))))

;;; Return a behaviorally identical copy of CODE.
(defun copy-code-object (code)
  ;; Must have one simple-fun
  (aver (= (code-n-entries code) 1))
  ;; Disallow relative instruction operands.
  ;; (This restriction could be removed by actually performing fixups)
  ;; x86-64 absolute fixups are OK since they will only point to static objects.
  #+x86-64
  (aver (not (nth-value
              1 (sb-c:unpack-code-fixup-locs (sb-vm::%code-fixups code)))))
  (let* ((nbytes (code-object-size code))
         (boxed (code-header-words code)) ; word count
         (unboxed (- nbytes (ash boxed sb-vm:word-shift))) ; byte count
         (copy (allocate-code-object :dynamic boxed unboxed)))
    (with-pinned-objects (code copy)
      (%byte-blt (code-instructions code) 0 (code-instructions copy) 0 unboxed)
      ;; copy boxed constants so that the fixup step (if needed) sees the 'fixups'
      ;; slot from the new object.
      (loop for i from 2 below boxed
            do (setf (code-header-ref copy i) (code-header-ref code i)))
      ;; x86 needs to fixup instructions that reference code constants,
      ;; and the jmp to TAIL-CALL-VARIABLE
      #+x86 (alien-funcall (extern-alien "gencgc_apply_code_fixups" (function void unsigned unsigned))
                           (- (get-lisp-obj-address code) sb-vm:other-pointer-lowtag)
                           (- (get-lisp-obj-address copy) sb-vm:other-pointer-lowtag))
      (assign-simple-fun-self (%code-entry-point copy 0)))
    copy))

;;; Note the existence of FUNCTION.
(defun note-fun (info function object)
  (declare (type function function)
           (type core-object object))
  (let ((patch-table (core-object-patch-table object)))
    (dolist (patch (gethash info patch-table))
      (setf (code-header-ref (car patch) (the index (cdr patch))) function))
    (remhash info patch-table))
  (setf (gethash info (core-object-entry-table object)) function)
  (values))

;;; Stick a reference to the function FUN in CODE-OBJECT at index I. If the
;;; function hasn't been compiled yet, make a note in the patch table.
(defun reference-core-fun (code-obj i fun object)
  (declare (type core-object object) (type functional fun)
           (type index i))
  (let* ((info (leaf-info fun))
         (found (gethash info (core-object-entry-table object))))
    (if found
        (setf (code-header-ref code-obj i) found)
        (push (cons code-obj i)
              (gethash info (core-object-patch-table object)))))
  (values))

;;; Dump a component to core. We pass in the assembler fixups, code
;;; vector and node info.
(defun make-core-component (component segment length fixup-notes object)
  (declare (type component component)
           (type segment segment)
           (type index length)
           (list fixup-notes)
           (type core-object object))
  (let ((debug-info (debug-info-for-component component)))
    (let* ((2comp (component-info component))
           (constants (ir2-component-constants 2comp))
           (nboxed (align-up (length constants) sb-c::code-boxed-words-align))
           (code-obj (allocate-code-object
                      (component-mem-space component) nboxed length)))

      ;; The following operations need the code pinned:
      ;; 1. copying into code-instructions (a SAP)
      ;; 2. apply-core-fixups and sanctify-for-execution
      (with-pinned-objects (code-obj)
        (let ((bytes (the (simple-array assembly-unit 1)
                          (segment-contents-as-vector segment))))
          ;; By design, until the last 2 unboxed bytes of CODE-OBJ contain a
          ;; nonzero value, GC will not see any simple-funs therein.
          (%byte-blt bytes 0 (code-instructions code-obj) 0 (length bytes)))
        (apply-core-fixups fixup-notes code-obj))

      ;; Don't need code pinned now
      (let* ((entries (ir2-component-entries 2comp))
             (fun-index (length entries)))
        (dolist (entry-info entries)
          (let ((fun (%code-entry-point code-obj (decf fun-index)))
                (w (+ sb-vm:code-constants-offset
                      (* sb-vm:code-slots-per-simple-fun fun-index))))
            (setf (code-header-ref code-obj (+ w sb-vm:simple-fun-name-slot))
                  (entry-info-name entry-info)
                  (code-header-ref code-obj (+ w sb-vm:simple-fun-arglist-slot))
                  (entry-info-arguments entry-info)
                  (code-header-ref code-obj (+ w sb-vm:simple-fun-source-slot))
                  (entry-info-form/doc entry-info)
                  (code-header-ref code-obj (+ w sb-vm:simple-fun-info-slot))
                  (entry-info-type/xref entry-info))
            (note-fun entry-info fun object))))

      (push debug-info (core-object-debug-info object))
      (setf (%code-debug-info code-obj) debug-info)

      (do ((index sb-vm:code-constants-offset (1+ index)))
          ((>= index (length constants)))
        (let ((const (aref constants index)))
            (etypecase const
              (null)
              (constant
               (setf (code-header-ref code-obj index)
                     (constant-value const)))
              (list
               (ecase (car const)
                 (:entry
                  (reference-core-fun code-obj index (cadr const) object))
                 (:fdefinition
                  (setf (code-header-ref code-obj index)
                        (find-or-create-fdefn (cadr const))))
                 (:known-fun
                  (setf (code-header-ref code-obj index)
                        (%coerce-name-to-fun (cadr const)))))))))))
  (values))

;;; Backpatch all the DEBUG-INFOs dumped so far with the specified
;;; SOURCE-INFO list. We also check that there are no outstanding
;;; forward references to functions.
(defun fix-core-source-info (info object &optional function)
  (declare (type core-object object))
  (declare (type (or null function) function))
  (aver (zerop (hash-table-count (core-object-patch-table object))))
  (let ((source (debug-source-for-info info :function function)))
    (dolist (info (core-object-debug-info object))
      (setf (debug-info-source info) source)))
  (setf (core-object-debug-info object) nil)
  (values))
