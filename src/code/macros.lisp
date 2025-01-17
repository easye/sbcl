;;;; lots of basic macros for the target SBCL

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-IMPL")

;;;; ASSERT and CHECK-TYPE

;;; ASSERT is written this way, to call ASSERT-ERROR, because of how
;;; closures are compiled. RESTART-CASE has forms with closures that
;;; the compiler causes to be generated at the top of any function
;;; using RESTART-CASE, regardless of whether they are needed. Thus if
;;; we just wrapped a RESTART-CASE around the call to ERROR, we'd have
;;; to do a significant amount of work at runtime allocating and
;;; deallocating the closures regardless of whether they were ever
;;; needed.
;;;
;;; ASSERT-ERROR isn't defined until a later file because it uses the
;;; macro RESTART-CASE, which isn't defined until a later file.
;;;
(sb-xc:defmacro assert (test-form &optional places datum &rest arguments
                            &environment env)
  "Signals an error if the value of TEST-FORM is NIL. Returns NIL.

   Optional DATUM and ARGUMENTS can be used to change the signaled
   error condition and are interpreted as in (APPLY #'ERROR DATUM
   ARGUMENTS).

   Continuing from the signaled error using the CONTINUE restart will
   allow the user to alter the values of the SETFable locations
   specified in PLACES and then start over with TEST-FORM.

   If TEST-FORM is of the form

     (FUNCTION ARG*)

   where FUNCTION is a function (but not a special operator like
   CL:OR, CL:AND, etc.) the results of evaluating the ARGs will be
   included in the error report if the assertion fails."
  (collect ((bindings) (infos))
    (let* ((func (if (listp test-form) (car test-form)))
           (new-test
            (if (and (typep func '(and symbol (not null)))
                     (not (sb-xc:macro-function func env))
                     (not (sb-xc:special-operator-p func))
                     (proper-list-p (cdr test-form)))
                ;; TEST-FORM is a function call. We do not attempt this
                ;; if TEST-FORM is a macro invocation or special form.
                `(,func ,@(mapcar (lambda (place)
                                    (if (sb-xc:constantp place env)
                                        place
                                        (with-unique-names (temp)
                                          (bindings `(,temp ,place))
                                          (infos `',place)
                                          (infos temp)
                                          temp)))
                                  (rest test-form)))
                ;; For all other cases, just evaluate TEST-FORM
                ;; and don't report any details if the assertion fails.
                test-form))
           (try '#:try)
           (done  '#:done))
      ;; If TEST-FORM, potentially using values from BINDINGS, does not
      ;; hold, enter a loop which reports the assertion error,
      ;; potentially changes PLACES, and retries TEST-FORM.
      `(tagbody
        ,try
          (let ,(bindings)
            (when ,new-test
              (go ,done))

            (assert-error ',test-form
                          ,@(and (infos)
                                 `(,(/ (length (infos)) 2)))
                          ,@(infos)
                          ,@(and (or places datum
                                     arguments)
                                 `(',places))
                          ,@(and (or places datum
                                     arguments)
                                 `(,datum))
                          ,@arguments))
          ,@(mapcar (lambda (place)
                      `(setf ,place (assert-prompt ',place ,place)))
                    places)
          (go ,try)
        ,done))))

(defun assert-prompt (name value)
  (cond ((y-or-n-p "The old value of ~S is ~S.~
                    ~%Do you want to supply a new value? "
                   name value)
         (format *query-io* "~&Type a form to be evaluated:~%")
         (flet ((read-it () (eval (read *query-io*))))
           (if (symbolp name) ;help user debug lexical variables
               (progv (list name) (list value) (read-it))
               (read-it))))
        (t value)))

;;; CHECK-TYPE is written this way, to call CHECK-TYPE-ERROR, because
;;; of how closures are compiled. RESTART-CASE has forms with closures
;;; that the compiler causes to be generated at the top of any
;;; function using RESTART-CASE, regardless of whether they are
;;; needed. Because it would be nice if CHECK-TYPE were cheap to use,
;;; and some things (e.g., READ-CHAR) can't afford this excessive
;;; consing, we bend backwards a little.
;;;
;;; CHECK-TYPE-ERROR isn't defined until a later file because it uses
;;; the macro RESTART-CASE, which isn't defined until a later file.
(sb-xc:defmacro check-type (place type &optional type-string
                                &environment env)
  "Signal a restartable error of type TYPE-ERROR if the value of PLACE
is not of the specified type. If an error is signalled and the restart
is used to return, this can only return if the STORE-VALUE restart is
invoked. In that case it will store into PLACE and start over."
  ;; Detect a common user-error.
  (when (and (consp type) (eq 'quote (car type)))
    (error 'simple-reference-error
           :format-control "Quoted type specifier in ~S: ~S"
           :format-arguments (list 'check-type type)
           :references '((:ansi-cl :macro check-type))))
  ;; KLUDGE: We use a simpler form of expansion if PLACE is just a
  ;; variable to work around Python's blind spot in type derivation.
  ;; For more complex places getting the type derived should not
  ;; matter so much anyhow.
  (let ((expanded (%macroexpand place env)))
    (if (symbolp expanded)
        `(do ()
             ((typep ,place ',type))
           (setf ,place (check-type-error ',place ,place ',type
                                          ,@(and type-string
                                                 `(,type-string)))))
        (let ((value (gensym)))
          `(do ((,value ,place ,place))
               ((typep ,value ',type))
             (setf ,place
                   (check-type-error ',place ,value ',type
                                     ,@(and type-string
                                            `(,type-string)))))))))

;;;; DEFINE-SYMBOL-MACRO

(sb-xc:defmacro define-symbol-macro (name expansion)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
    (sb-c::%define-symbol-macro ',name ',expansion (sb-c:source-location))))

(defun sb-c::%define-symbol-macro (name expansion source-location)
  (unless (symbolp name)
    (error 'simple-type-error :datum name :expected-type 'symbol
           :format-control "Symbol macro name is not a symbol: ~S."
           :format-arguments (list name)))
  (with-single-package-locked-error
      (:symbol name "defining ~A as a symbol-macro"))
  (let ((kind (info :variable :kind name)))
    (case kind
     ((:macro :unknown)
      (when source-location
        (setf (info :source-location :symbol-macro name) source-location))
      (setf (info :variable :kind name) :macro)
      (setf (info :variable :macro-expansion name) expansion))
     (t
      (%program-error "Symbol ~S is already defined as ~A."
                      name (case kind
                             (:alien "an alien variable")
                             (:constant "a constant")
                             (:special "a special variable")
                             (:global "a global variable")
                             (t kind))))))
  name)

;;;; DEFINE-COMPILER-MACRO

(sb-xc:defmacro define-compiler-macro (name lambda-list &body body)
  "Define a compiler-macro for NAME."
  (check-designator name define-compiler-macro)
  (when (and (symbolp name) (special-operator-p name))
    (%program-error "cannot define a compiler-macro for a special operator: ~S"
                    name))
  ;; DEBUG-NAME is called primarily for its side-effect of asserting
  ;; that (COMPILER-MACRO-FUNCTION x) is not a legal function name.
  (let ((def (make-macro-lambda (sb-c::debug-name 'compiler-macro name)
                                lambda-list body 'define-compiler-macro name
                                :accessor 'sb-c::compiler-macro-args)))
    `(progn
          (eval-when (:compile-toplevel)
           (sb-c::%compiler-defmacro :compiler-macro-function ',name))
          (eval-when (:compile-toplevel :load-toplevel :execute)
           (sb-c::%define-compiler-macro ',name ,def)))))

(eval-when (#-sb-xc :compile-toplevel :load-toplevel :execute)
  (defun sb-c::%define-compiler-macro (name definition)
    (sb-c::warn-if-compiler-macro-dependency-problem name)
    ;; FIXME: warn about incompatible lambda list with
    ;; respect to parent function?
    (setf (sb-xc:compiler-macro-function name) definition)
    name))

;;;; CASE, TYPECASE, and friends

;;; Make this a full warning during SBCL build.
#+sb-xc ; Don't redefine if recompiling in a warm REPL
(define-condition duplicate-case-key-warning (#-sb-xc-host style-warning #+sb-xc-host warning)
  ((key :initarg :key
        :reader case-warning-key)
   (case-kind :initarg :case-kind
              :reader case-warning-case-kind)
   (occurrences :initarg :occurrences
                :type list
                :reader duplicate-case-key-warning-occurrences))
  (:report
    (lambda (condition stream)
      (format stream
        "Duplicate key ~S in ~S form, ~
         occurring in~{~#[~; and~]~{ the ~:R clause:~%~<  ~S~:>~}~^,~}."
        (case-warning-key condition)
        (case-warning-case-kind condition)
        (duplicate-case-key-warning-occurrences condition)))))

#|
;;; ---------------------------------------------------------------------------
;;; And now some theory about how to turn CASE expressions which dispatch on
;;; symbols into expressions which dispatch on numbers instead. The idea is
;;; to use SYMBOL-HASH. It is easily enforceable that symbols referenced from
;;; compiled code have a hash, though generally SYMBOL-HASH is lazily computed.
;;; The masked hash maps to an integer from 0 to (ASH 1 nbits) which will be
;;; dispatched via a jump table on compiler backends which support jump tables.

;;; There are complications that make any naive attempt to dispatch on hash
;;; inadmissible. First off, any symbol could hash to the hash of a symbol
;;; in the dispatched set, so there always has to be a check for a match on
;;; the symbol. That's the easy part. The difficulty is figuring out what to
;;; do with hash collisions; but worse, symbols within a given clause of the
;;; CASE (having the same consequent) may hash differently.
;;; Consider one example.

(CASE sym
 ((u v) (cc1)) ; "CC" designates the "canonical clause" in that ordinal position
 ((w x) (cc2))
 ((y z) (cc3)))

;;; In reality, we would probably find a subset of bits of SYMBOL-HASH producing
;;; unique bins, but suppose for argument's sake that there are collisions:

hash bin 0: (u . cc1) (w . cc2)
hash bin 1: (v . cc1) (y . cc3)
hash bin 2: (x . cc2) (z . cc3)
hash bin 3: - empty -

;;; Something has to be done to resolve the selection of the consequent.
;;; Described below are 4 possible techniques.

;;; Option (I)
;;; Syntactically repeat clause consequents giving a literal rendering
;;; of the hash-table.  This is a poor choice unless the consequent
;;; is a self-evaluating object. But it has the nice property of invoking
;;; at most one IF after the jump-table-based dispatch.

(case hash
  (0 (if (eq sym 'u) (cc1) (cc2)))  ; each canonical consequent appears twice
  (1 (if (eq sym 'v) (cc1) (cc3)))
  (2 (if (eq sym 'x) (cc2) (cc3))))

;;; Option (II)
;;; Merge bins to create equivalence classes by canonical clause.

(case hash
  ((0 1) (case sym (y (cc3)) (w (cc2)) (otherwise (cc1))))
  (2 (if (eq sym 'x) (cc2) (cc3)))

;;; So this expansion has avoided inserting the s-expression CC1 more than once,
;;; but it inserts CC2 and CC3 each twice.  If those are not self-evaluating
;;; literals, then we should further merge (0 1) with (2). Doing the second
;;; merge lumps everything into 1 bin which is as bad as, if not worse than,
;;; a chain if IF expressions testing the original symbol.
;;; i.e. bin merging could make the hashing operation pointless.

;;; Option (III)
;;; Use a "two-stage" decode.
;;; This makes the consequent of the inner case side-effect free,
;;; but is probably not great for performance, though is an elegant
;;; rendition of the equivalence class technique.

(let ((original-clause-index
       (case hash
        (0 (if (eq sym 'u) 1 2))
        (1 (if (eq sym 'v) 1 3))
        (2 (if (eq sym 'x) 2 3)))))
  (case original-clause-index (1 (cc1)) (2 (cc2)) (3 (cc3))))

;;; Option (IV)
;;; Expand involving a tagbody, which though slightly ugly, presumably produces
;;; decent assembly code.

(block b
 (tagbody

   (case hash
     (0 (if (eq sym 'u) (go clause1) (go clause2)))
     (1 (if (eq sym 'v) (go clause1) (go clause3)))
     (2 (if (eq sym 'x) (go clause2) (go clause3))))
   clause1 (return-from b (progn (cc1)))
   clause2 (return-from b (progn (cc2)))
   ...))

;;; Additionally, if some bin has only 1 possibility, the GO is elided
;;; and we can just do (return-from b (consequent)).

;;; In practice, the expander does something not entirely unlike any of the above.
;;; It will insert a consequent more than one time if it is a self-evaluating object,
;;; and it will merge bins provided that the merging is simple and does not
;;; introduce any new IF expressions.

;;; A minimal example that won't work - after forcing the expander to try to
;;; operate on just 4 symbols which normally it would not try to process:
;;; (CASE (H) ((U V) (F)) ((:U :Z) Y))
clause 0 -> bins (2 3)
clause 1 -> bins (1 2)
bin 0 -> NIL
bin 1 -> ((:Z . 1))
bin 2 -> ((:U . 1) (U . 0))
bin 3 -> ((V . 0))
symbol-case giving up: case=((V U) (F))

;;; ---------------------------------------------------------------------------
|#

;;; For the specified symbols, choose bits from the hash producing as near a
;;; perfect hash function as can be achived without resorting to extraction
;;; and mixing of discontiguous bits.
;;; This will fail to find a unique hash if there are symbols whose names are
;;; spelled the same, since their SXHASHes are the same.
;;;
;;; HASH-FUN is taken as an argument mainly for testing purposes so that any
;;; behavior can be simulated without having to bother with finding symbols
;;; whose SXHASH hashes collide.
;;;
;;; FIXME: If not a perfect hash, then the best choice should be informed by a
;;; cost function that takes into account which symbols share a clause of the
;;; CASE form. Prefer collisions on symbols whose consequent in the CASE
;;; is the same, otherwise the expansion becomes convoluted.

(defun pick-best-symbol-hash-bits (symbols hash-fun
                                   &optional (maxbits sb-vm:n-positive-fixnum-bits))
  (let* ((nsymbols (length symbols))
        (nhashes (power-of-two-ceiling nsymbols))
        (smallest-nbits (1- (integer-length nhashes)))
        (nbits smallest-nbits)
        (hashes (mapcar hash-fun symbols))
        (best-bytepos nil)
        ;; "best" means smallest
        (best-max-bin-count sb-xc:most-positive-fixnum) ; sentinel value
        (best-average sb-xc:most-positive-fixnum))
    (dotimes (try 2 (values best-max-bin-count best-bytepos))
      (let ((bin-counts (make-array (ash 1 nbits) :initial-element 0)))
        (dotimes (pos (- (1+ maxbits) nbits))
          (fill bin-counts 0)
          (dolist (hash hashes)
            (incf (aref bin-counts (ldb (byte nbits pos) hash))))
          ;; Compute the average number of items per bin,
          ;; looking only at bins that contain something.
          ;; It does not improve things to increase the total bins
          ;; without distributing items into at least 1 more bin.
          (let ((max-bin-count 0) (n-used 0))
            (dovector (count bin-counts)
              (when (plusp count) (incf n-used))
              (setf max-bin-count (max count max-bin-count)))
            (when (= max-bin-count 1) ; can't beat a perfect hash
              (return-from pick-best-symbol-hash-bits
                (values 1 (byte nbits pos))))
            (let ((average (/ nsymbols n-used)))
              #+nil (format t "(byte ~d ~d) ~s avg=~a max=~a~%"
                            nbits pos bin-counts average max-bin-count)
              (when (or (< max-bin-count best-max-bin-count)
                        (and (= max-bin-count best-max-bin-count)
                             (< average best-average)))
                (setq best-bytepos (byte nbits pos)
                      best-max-bin-count max-bin-count
                      best-average average))))))
      (incf nbits))))

;;; Turn a case over symbols into a case over their hashes.
;;; Regarding the apparently redundant UNREACHABLE branches:
;;; The first one causes the total number of ways to be (ASH 1 NBITS) exactly.
;;; The second allows proper type derivation, because otherwise it is not obvious
;;; (to the compiler) that all prior COND clauses were exhaustive.
;;; This actually matters to to encoding of alien ENUM types. In the conventional
;;; expansion of ECASE, all branches cover the enum, and the failure branch
;;; ensures non-return of anything but an integer.
;;; In the fancy expansion, we would get a compile-time error:
;;;   debugger invoked on a SIMPLE-ERROR in thread
;;;   #<THREAD "main thread" RUNNING {10005304C3}>:
;;;     #<SB-C:TN t1 :NORMAL> is not valid as the first argument to VOP:
;;;     SB-VM::MOVE-WORD-ARG
;;; without the UNREACHABLE branch, because the expansion otherwise
;;; looked as if the COND might return NIL.
(defun expand-symbol-case (keyform clauses keys errorp hash-fun)
  (declare (ignorable keyform clauses keys errorp))
  ;; for few keys, the clever algorithm  probably gives no better performance
  ;; - and potentially worse - than the CPU's branch predictor.
  (unless (>= (length keys) 6)
    (return-from expand-symbol-case nil))
  (multiple-value-bind (maxprobes byte) (pick-best-symbol-hash-bits keys hash-fun)
    ;; (format t "maxprobes ~d byte ~s~%" maxprobes byte)
    (when (> maxprobes 2) ; Give up (for now) if more than 2 keys hash the same.
      #+sb-devel (format t "~&symbol-case giving up: probes=~d byte=~d~%"
                         maxprobes byte)
      (return-from expand-symbol-case nil))
    (let* ((default (when (eql (caar clauses) 't) (pop clauses)))
           (unique-symbols)
           (clauses
            ;; This is crummy, but we first have to undo our pre-expansion
            ;; and remove dups. Otherwise the (BUG "Messup") below could occur.
            (mapcar
             (lambda (clause)
               (destructuring-bind (antecedent . consequent) clause
                 (aver (typep consequent '(cons (eql nil))))
                 (pop consequent) ; strip the NIL that CASE-BODY inserts
                 (when (typep antecedent '(cons (eql eql)))
                   (setq antecedent `(or ,antecedent)))
                 (flet ((extract-key (form) ; (EQL #:gN (QUOTE foo)) -> FOO
                          (let ((third (third form)))
                            (aver (typep third '(cons (eql quote))))
                            (the symbol (second third)))))
                   (let (clause-symbols)
                     ;; De-duplicate across all clauses and within each clause
                     ;; due to possible extreme stupidity in source code.
                     (dolist (term (cdr antecedent))
                       (aver (typep term '(cons (eql eql))))
                       (let ((symbol (extract-key term)))
                         (unless (member symbol unique-symbols)
                           (push symbol unique-symbols)
                           (push symbol clause-symbols))))
                     (if clause-symbols ; all symbols could have dropped out
                         (cons clause-symbols consequent)
                         ;; give up. There are reasons the compiler should see
                         ;; all subforms. Maybe not good reasons.
                         (return-from expand-symbol-case nil))))))
             (reverse clauses)))
           (clause->bins (make-array (length clauses) :initial-element nil))
           (bins (make-array (ash 1 (byte-size byte)) :initial-element 0))
           (symbol (sb-xc:gensym "S"))
           (hash (sb-xc:gensym "H"))
           (is-hashable
            ;; For x86-64, any non-immediate object is considered hashable,
            ;; so we only do a lowtag test on the object, though the correct hash
            ;; is obtained only if the object is a symbol.
            #+x86-64 `(pointerp ,symbol)
            ;; For others backends, the set of keys in a particular CASE form
            ;; makes a difference. NIL as a possible key mandates choosing SYMBOLP
            ;; but NON-NULL-SYMBOL-P is the quicker test.
            #-x86-64 `(,(if (member nil keys) 'symbolp 'non-null-symbol-p) ,symbol))
           (calc-hash
            `(ldb (byte ,(byte-size byte)
                        ,(byte-position byte))
                  ;; Always access the pre-memoized value in the hash slot.
                  ;; SYMBOL-HASH* reads the word following the header word
                  ;; in any pointer object regardless of lowtag.
                  #+x86-64
                  ,(if (eq hash-fun 'sxhash)
                       `(symbol-hash* ,symbol nil)
                       `(,hash-fun ,symbol))
                  ;; For others, use SYMBOL-HASH.
                  #-x86-64
                  (,(if (eq hash-fun 'sxhash) 'symbol-hash hash-fun) ,symbol))))
      (declare (ignorable default))

      (flet ((trivial-result-p (clause)
               ;; Return 2 values: T/NIL if the clause's consequent
               ;; is trivial, and its value when trivial.
               (let ((consequent (cdr clause)))
                 (if (singleton-p consequent)
                     (let ((form (car consequent)))
                       (cond ((typep form '(cons (eql quote) (cons t null)))
                              (values t (cadr form)))
                             ((self-evaluating-p form) (values t form))
                             (t (values nil nil))))
                     ;; NIL -> T, otherwise -> NIL
                     (values (not consequent) nil)))))

        ;; Try doing an array lookup if the hashing has no collisions and
        ;; every consequent is trivial.
        (when (= maxprobes 1)
          (block try-table-lookup
            (let ((values (make-array (length bins)))
                  (types nil))
              (dolist (clause clauses)
                (multiple-value-bind (trivialp value) (trivial-result-p clause)
                  (unless trivialp
                    (return-from try-table-lookup))
                  (push (ctype-of value) types)
                  (dolist (symbol (car clause))
                    (let ((index (ldb byte (funcall hash-fun symbol))))
                      (aver (eql (aref bins index) 0)) ; no collisions
                      (setf (aref bins index) symbol
                            (aref values index) value)))))
              (return-from expand-symbol-case
                `(let ((,hash 0)
                       (,symbol ,keyform))
                   (if (and ,is-hashable (eq ,symbol (svref ,bins (setq ,hash ,calc-hash))))
                       (truly-the ,(type-specifier (apply #'type-union types))
                                  (aref ,(sb-c::coerce-to-smallest-eltype values) ,hash))
                       ,(if errorp
                            ;; coalescing of simple-vectors in a saved core
                            ;; could eliminate repeated data from the same
                            ;; ECASE that gets inlined many times over.
                            `(ecase-failure
                              ,symbol ,(coerce keys 'simple-vector))
                            `(progn ,@(cddr default)))))))))

        ;; Reset the bins, try it the long way
        (fill bins nil)
        ;; Place each symbol into its hash bin. Also, for each clause compute the
        ;; set of hash bins that it has placed a symbol into.
        (loop for clause in clauses for clause-index from 0
              do (dolist (symbol (car clause))
                   (let ((masked-hash (ldb byte (funcall hash-fun symbol))))
                     (pushnew masked-hash (aref clause->bins clause-index))
                     (push (cons symbol clause-index) (aref bins masked-hash)))))
        ;; Canonically order each element of clause->bins
        (dotimes (i (length clause->bins))
          (setf (aref clause->bins i) (sort (aref clause->bins i) #'<)))

        ;; Perform a very limited bin merging step as follows: if a clause
        ;; placed its symbols in more than one bin, allow it provided that either:
        ;; - the clause's consequent is trivial, OR
        ;; - none of its bins contains a symbol from a different clause.
        ;; In the former case, we don't need to merge bins.
        ;; In the latter case, the bins define an equivalence class
        ;; that does not intersect any other equivalence class.
        ;;
        ;; To make this work, if a bin requires an IF to disambiguate which consequent
        ;; to take, then it is removed from the clase->bins entry for each clause
        ;; for which it contains a consequent so that the code below which computes
        ;; the COND does not see the bin as a member of any equivalence class.
        ;; Pass 1: decide whether to give up or go on.
        (loop for clause in clauses for clause-index from 0
              do (let ((equivalence-class (aref clause->bins clause-index)))
                   ;; if a nontrivial consequent is distributed into
                   ;; more than one hash bin ...
                   (when (and (cdr equivalence-class)
                              (not (trivial-result-p clause)))
                     (dolist (bin-index (aref clause->bins clause-index))
                       (dolist (item (aref bins bin-index))
                         (unless (eql (cdr item) clause-index)
                           #+sb-devel (format t "~&symbol-case gives up: case=~s~%" clause)
                           (return-from expand-symbol-case)))))))
        ;; Pass 2: remove bins with more than one consequent from their
        ;; clause equivalence class.
        ;; Maybe these passes could be combined, but I'd rather conservatively
        ;; preserve accumulated data thus far before wrecking it.
        (dotimes (bin-index (length bins))
          (let ((unique-clause-indices
                 (remove-duplicates (mapcar #'cdr (aref bins bin-index)))))
            (when (cdr unique-clause-indices)
              (dolist (clause-index unique-clause-indices)
                (setf (aref clause->bins clause-index)
                      (delete bin-index (aref clause->bins clause-index))))))))

      ;; Compute the COND clauses over the range of hash values.
      (let ((sym-vectors (loop repeat maxprobes
                               collect (make-array (length bins) :initial-element 0)))
            (cond-clauses))
        ;; For each nonempty bin:
        ;; - If it contains >1 consequent, then arbitrarily pick one symbol to test
        ;;   to see which consequent pertains.
        ;; - Otherwise, it contains exactly one consequent. See if the bin's equivalence
        ;;   class has >1 item. If it does, insert for only a representative element.
        ;;   By the above construction, no other bin in the class can have >1 consequent.
        (flet ((action (clause-index)
                 (let ((clause (nth clause-index clauses)))
                   (or (cdr clause) '(nil)))))
          (dotimes (bin-index (length bins))
            (let* ((bin-contents (aref bins bin-index))
                   (unique-clause-indices
                    (remove-duplicates (mapcar #'cdr bin-contents)))
                   (cond-clause
                    (cond ((cdr unique-clause-indices)
                           ;; Exactly 2 actions in the bin due to hardcoded limitation
                           ;; on the implementation of collision resolution.
                           `((eql ,hash ,bin-index)
                             (cond ((eq ,symbol ',(caar bin-contents))
                                    ,@(action (cdar bin-contents)))
                                   (t
                                    ,@(action (cdadr bin-contents))))))
                          (unique-clause-indices
                           (let* ((clause-index (car unique-clause-indices))
                                  (equivalence-class (aref clause->bins clause-index)))
                             (when (eql bin-index (car equivalence-class))
                               ;; This is the representative bin of a class
                               `(,(if (cdr equivalence-class)
                                      `(or ,@(mapcar (lambda (x) `(eql ,hash ,x))
                                                     equivalence-class))
                                      `(eql ,hash ,bin-index))
                                 ,@(action clause-index))))))))
              (when cond-clause (push cond-clause cond-clauses)))))

        ;; Fill in the symbol probing vectors.
        (dotimes (hash (length bins))
          (let ((contents (aref bins hash)))
            (dolist (item contents)
              (dotimes (i maxprobes (bug "Messup in CASE vectors for ~S" keys))
                (when (eql (svref (nth i sym-vectors) hash) 0)
                  (setf (svref (nth i sym-vectors) hash) (car item))
                  (return))))))

        ;; Produce the COND
        ;; But no other backend supports multiway branching,
        ;; so return now, and not sooner, so that:
        ;; - we can test the above logic (for AVER failures) on all platforms
        ;; - no "unreachable code" notes are printed about this function
        ;;   if we were to return early.
        ;; So, just joking, maybe don't produce the COND.
        #+(or x86 x86-64)
        (let ((block (sb-xc:gensym "B"))
              (unused-bins))
          ;; Take note of the unused bins
          (dotimes (i (length bins))
            (unless (aref bins i) (push i unused-bins)))
          `(let ((,symbol ,keyform))
             (block ,block
               (when ,is-hashable
                 (let ((,hash ,calc-hash))
                   ;; At most two probes are required, and usually just 1
                   (when ,(ecase maxprobes
                            (1 `(eq (svref ,(elt sym-vectors 0) ,hash) ,symbol))
                            (2 `(or (eq (svref ,(elt sym-vectors 0) ,hash) ,symbol)
                                    (eq (svref ,(elt sym-vectors 1) ,hash) ,symbol))))
                     (return-from ,block
                       (cond ,@(nreverse cond-clauses)
                             ,@(when unused-bins
                                 ;; to make it clear that the number of "ways"
                                 ;; is the exact right number- I'm hoping this will help
                                 ;; elide the bounds check in multiway-branch. TBD
                                 `(((or ,@(mapcar (lambda (x) `(eql ,hash ,x))
                                                  (nreverse unused-bins)))
                                    (unreachable))))
                             (t (unreachable)))))))
               ,@(if errorp
                     `((ecase-failure ,symbol ,(coerce keys 'simple-vector)))
                     (cddr default)))))))))

;;; CASE-BODY returns code for all the standard "case" macros. NAME is
;;; the macro name, and KEYFORM is the thing to case on. MULTI-P
;;; indicates whether a branch may fire off a list of keys; otherwise,
;;; a key that is a list is interpreted in some way as a single key.
;;; When MULTI-P, TEST is applied to the value of KEYFORM and each key
;;; for a given branch; otherwise, TEST is applied to the value of
;;; KEYFORM and the entire first element, instead of each part, of the
;;; case branch. When ERRORP, no OTHERWISE-CLAUSEs are recognized,
;;; and an ERROR form is generated where control falls off the end
;;; of the ordinary clauses. When PROCEEDP, it is an error to
;;; omit ERRORP, and the ERROR form generated is executed within a
;;; RESTART-CASE allowing KEYFORM to be set and retested.

;;; Note the absence of EVAL-WHEN here. The cross-compiler calls this function
;;; and gets the compiled code that the host produced in make-host-1.
;;; If recompiled, you do not want an interpreted definition that might come
;;; from EVALing a toplevel form - the stack blows due to infinite recursion.
(defun case-body (name keyform cases multi-p test errorp proceedp needcasesp)
  (unless (or cases (not needcasesp))
    (warn "no clauses in ~S" name))
  (let ((keyform-value (gensym))
        (clauses ())
        (keys ())
        (keys-seen (make-hash-table :test #'eql)))
    (do* ((cases cases (cdr cases))
          (case (car cases) (car cases))
          (case-position 1 (1+ case-position)))
         ((null cases) nil)
      (flet ((check-clause (case-keys)
               (loop for k in case-keys
                  for existing = (gethash k keys-seen)
                  do (when existing
                       (warn 'duplicate-case-key-warning
                             :key k
                             :case-kind name
                             :occurrences `(,existing (,case-position (,case))))))
               (let ((record (list case-position (list case))))
                 (dolist (k case-keys)
                   (setf (gethash k keys-seen) record)))))
        (unless (list-of-length-at-least-p case 1)
          (with-current-source-form (cases)
            (error "~S -- bad clause in ~S" case name)))
        (with-current-source-form (case)
          (destructuring-bind (keyoid &rest forms) case
            (cond (;; an OTHERWISE-CLAUSE
                   ;;
                   ;; By the way... The old code here tried gave
                   ;; STYLE-WARNINGs for normal-clauses which looked as
                   ;; though they might've been intended to be
                   ;; otherwise-clauses. As Tony Martinez reported on
                   ;; sbcl-devel 2004-11-09 there are sometimes good
                   ;; reasons to write clauses like that; and as I noticed
                   ;; when trying to understand the old code so I could
                   ;; understand his patch, trying to guess which clauses
                   ;; don't have good reasons is fundamentally kind of a
                   ;; mess. SBCL does issue style warnings rather
                   ;; enthusiastically, and I have often justified that by
                   ;; arguing that we're doing that to detect issues which
                   ;; are tedious for programmers to detect for by
                   ;; proofreading (like small typoes in long symbol
                   ;; names, or duplicate function definitions in large
                   ;; files). This doesn't seem to be an issue like that,
                   ;; and I can't think of a comparably good justification
                   ;; for giving STYLE-WARNINGs for legal code here, so
                   ;; now we just hope the programmer knows what he's
                   ;; doing. -- WHN 2004-11-20
                   (and (not errorp) ; possible only in CASE or TYPECASE,
                                        ; not in [EC]CASE or [EC]TYPECASE
                        (memq keyoid '(t otherwise))
                        (null (cdr cases)))
                   ;; The NIL has a reason for being here: Without it, COND
                   ;; will return the value of the test form if FORMS is NIL.
                   (push `(t nil ,@forms) clauses))
                  ((and multi-p (listp keyoid))
                   (setf keys (nconc (reverse keyoid) keys))
                   (check-clause keyoid)
                   (push `((or ,@(mapcar (lambda (key)
                                           `(,test ,keyform-value ',key))
                                         keyoid))
                           nil
                           ,@forms)
                         clauses))
                  (t
                   (when (and (eq name 'case)
                              (cdr cases)
                              (memq keyoid '(t otherwise)))
                     (error 'simple-reference-error
                            :format-control
                            "~@<~IBad ~S clause:~:@_  ~S~:@_~S allowed as the key ~
                           designator only in the final otherwise-clause, not in a ~
                           normal-clause. Use (~S) instead, or move the clause to the ~
                           correct position.~:@>"
                            :format-arguments (list 'case case keyoid keyoid)
                            :references `((:ansi-cl :macro case))))
                   (push keyoid keys)
                   (check-clause (list keyoid))
                   (push `((,test ,keyform-value ',keyoid)
                           nil
                           ,@forms)
                         clauses)))))))
    (setq keys
          (nreverse (mapcon (lambda (tail)
                              (unless (member (car tail) (cdr tail))
                                (list (car tail))))
                            keys)))
    (case-body-aux name keyform keyform-value clauses keys errorp proceedp
                   `(,(if multi-p 'member 'or) ,@keys))))

;;; CASE-BODY-AUX provides the expansion once CASE-BODY has groveled
;;; all the cases. Note: it is not necessary that the resulting code
;;; signal case-failure conditions, but that's what KMP's prototype
;;; code did. We call CASE-BODY-ERROR, because of how closures are
;;; compiled. RESTART-CASE has forms with closures that the compiler
;;; causes to be generated at the top of any function using the case
;;; macros, regardless of whether they are needed.
;;;
;;; The CASE-BODY-ERROR function is defined later, when the
;;; RESTART-CASE macro has been defined.
(defun case-body-aux (name keyform keyform-value clauses keys
                      errorp proceedp expected-type)
  (when proceedp ; CCASE or CTYPECASE
    (return-from case-body-aux
      (let ((block (gensym))
            (again (gensym)))
        `(let ((,keyform-value ,keyform))
           (block ,block
             (tagbody
                ,again
                (return-from
                 ,block
                  (cond ,@(nreverse clauses)
                        (t
                         (setf ,keyform-value
                               (setf ,keyform
                                     (case-body-error
                                      ',name ',keyform ,keyform-value
                                      ',expected-type ',keys)))
                         (go ,again))))))))))

  (let ((implement-as name)
        (original-keys keys))
    (when (member name '(typecase etypecase))
      ;; Bypass all TYPEP handling if every clause of [E]TYPECASE is a MEMBER type.
      ;; More importantly, try to use the fancy expansion for symbols as keys.
      (let ((default (if (eq (caar clauses) 't) (car clauses)))
            (new-clauses))
        (collect ((new-keys))
          (dolist (clause (reverse (if default (cdr clauses) clauses))
                          (setq clauses (if default (cons default new-clauses) new-clauses)
                                keys (new-keys)
                                implement-as 'case))
            ;; clause is ((TYPEP #:x (QUOTE <sometype>)) NIL forms*)
            (destructuring-bind ((typep thing type-expr) . consequent) clause
              (declare (ignore thing))
              (unless (and (typep type-expr '(cons (eql quote) (cons t null)))
                           (eq typep 'typep))
                (bug "TYPECASE expander glitch"))
              (let* ((spec (second type-expr))
                     (clause-keys
                      (case (if (listp spec) (car spec))
                        (eql (when (singleton-p (cdr spec)) (list (cadr spec))))
                        (member (when (proper-list-p (cdr spec)) (cdr spec))))))
                (unless clause-keys (return))
                (dolist (key clause-keys)
                  (unless (member key (new-keys))
                    (new-keys key)))
                (push (cons `(or ,@(mapcar (lambda (x) `(eql ,keyform-value ',x))
                                           clause-keys))
                            consequent)
                      new-clauses)))))))

    ;; Efficiently expanding CASE over symbols depends on CASE over integers being
    ;; translated as a jump table. If it's not - as on most backends - then we use
    ;; the customary expansion as a series of IF tests.
    ;; Production code rarely uses CCASE, and the expansion differs such that
    ;; it doesn't seem worth the effort to handle it as a jump table.
    (when (and (member implement-as '(case ecase)) (every #'symbolp keys))
      (awhen (expand-symbol-case keyform clauses keys errorp 'sxhash)
        (return-from case-body-aux it)))

    `(let ((,keyform-value ,keyform))
       (declare (ignorable ,keyform-value)) ; e.g. (CASE KEY (T))
       (cond ,@(nreverse clauses)
             ,@(when errorp
                 `((t (,(ecase name
                          (etypecase 'etypecase-failure)
                          (ecase 'ecase-failure))
                       ,keyform-value ',original-keys))))))))

(sb-xc:defmacro case (keyform &body cases)
  "CASE Keyform {({(Key*) | Key} Form*)}*
  Evaluates the Forms in the first clause with a Key EQL to the value of
  Keyform. If a singleton key is T then the clause is a default clause."
  (case-body 'case keyform cases t 'eql nil nil nil))

(sb-xc:defmacro ccase (keyform &body cases)
  "CCASE Keyform {({(Key*) | Key} Form*)}*
  Evaluates the Forms in the first clause with a Key EQL to the value of
  Keyform. If none of the keys matches then a correctable error is
  signalled."
  (case-body 'ccase keyform cases t 'eql t t t))

(sb-xc:defmacro ecase (keyform &body cases)
  "ECASE Keyform {({(Key*) | Key} Form*)}*
  Evaluates the Forms in the first clause with a Key EQL to the value of
  Keyform. If none of the keys matches then an error is signalled."
  (case-body 'ecase keyform cases t 'eql t nil t))

(sb-xc:defmacro typecase (keyform &body cases)
  "TYPECASE Keyform {(Type Form*)}*
  Evaluates the Forms in the first clause for which TYPEP of Keyform and Type
  is true."
  (case-body 'typecase keyform cases nil 'typep nil nil nil))

(sb-xc:defmacro ctypecase (keyform &body cases)
  "CTYPECASE Keyform {(Type Form*)}*
  Evaluates the Forms in the first clause for which TYPEP of Keyform and Type
  is true. If no form is satisfied then a correctable error is signalled."
  (case-body 'ctypecase keyform cases nil 'typep t t t))

(sb-xc:defmacro etypecase (keyform &body cases)
  "ETYPECASE Keyform {(Type Form*)}*
  Evaluates the Forms in the first clause for which TYPEP of Keyform and Type
  is true. If no form is satisfied then an error is signalled."
  (case-body 'etypecase keyform cases nil 'typep t nil t))

;;; Compile a version of BODY for all TYPES, and dispatch to the
;;; correct one based on the value of VAR. This was originally used
;;; only for strings, hence the name. Renaming it to something more
;;; generic might not be a bad idea.
(sb-xc:defmacro string-dispatch ((&rest types) var &body body)
  (let ((fun (sb-xc:gensym "STRING-DISPATCH-FUN")))
    `(flet ((,fun (,var)
              ,@body))
       (declare (inline ,fun))
       (etypecase ,var
         ,@(loop for type in types
                 ;; TRULY-THE allows transforms to take advantage of the type
                 ;; information without need for constraint propagation.
                 collect `(,type (,fun (truly-the ,type ,var))))))))

;;;; WITH-FOO i/o-related macros

(sb-xc:defmacro with-open-stream ((var stream) &body body)
  (multiple-value-bind (forms decls) (parse-body body nil)
    `(let ((,var ,stream))
       ,@decls
       (unwind-protect
            (progn ,@forms)
         (close ,var)))))

(sb-xc:defmacro with-open-file ((stream filespec &rest options)
                                &body body)
  (multiple-value-bind (forms decls) (parse-body body nil)
    (let ((abortp (gensym)))
      `(let ((,stream (open ,filespec ,@options))
             (,abortp t))
         ,@decls
         (unwind-protect
              (multiple-value-prog1
                  (progn ,@forms)
                (setq ,abortp nil))
           (when ,stream
             (close ,stream :abort ,abortp)))))))

(sb-xc:defmacro with-input-from-string ((var string &key index start end)
                                            &body forms-decls)
  (multiple-value-bind (forms decls) (parse-body forms-decls nil)
    `(let ((,var
            ;; Should (WITH-INPUT-FROM-STRING (stream str :start nil :end 5))
            ;; pass the explicit NIL, and thus get an error? It's logical
            ;; because an explicit NIL does not mean "default" in any other
            ;; string operation. So why does it here?
            ,(if (null end)
                 `(make-string-input-stream ,string ,@(if start (list start)))
                 `(make-string-input-stream ,string ,(or start 0) ,end))))
         ,@decls
         (multiple-value-prog1
             (unwind-protect
                  (progn ,@forms)
               (close ,var))
           ,@(when index
               `((setf ,index (string-input-stream-current ,var))))))))

(sb-xc:defmacro with-output-to-string
    ((var &optional string &key (element-type ''character))
     &body forms-decls)
  (multiple-value-bind (forms decls) (parse-body forms-decls nil)
    (if string
        (let ((element-type-var (gensym)))
          `(let ((,var (make-fill-pointer-output-stream ,string))
                 ;; ELEMENT-TYPE isn't currently used for anything
                 ;; (see FILL-POINTER-OUTPUT-STREAM FIXME in stream.lisp),
                 ;; but it still has to be evaluated for side-effects.
                 (,element-type-var ,element-type))
             (declare (ignore ,element-type-var))
             ,@decls
             (unwind-protect
                  (progn ,@forms)
               (close ,var))))
        ;; I don't see why we need the unwind-protect.
        ;; CLHS says: "The output string stream to which the variable /var/
        ;; is bound has dynamic extent; its extent ends when the form is exited."
        ;; So technically you can't reference the stream after the string
        ;; is returned. And since the implication is that we can legally DXify
        ;; the stream, what difference does it make whether it's open or closed?
        ;; Certainly in code that is compiled in SAFETY < 3 we should
        ;; just not bother with the unwind-protect or the close.
        `(let ((,var (make-string-output-stream
                      ;; CHARACTER is the default element-type of
                      ;; string-ouput-stream, save a few bytes when passing it
                      ,@(and (not (equal element-type ''character))
                             `(:element-type ,element-type)))))
           ,@decls
           (unwind-protect
                (progn ,@forms)
             (close ,var))
           (get-output-stream-string ,var)))))

;;;; miscellaneous macros

(sb-xc:defmacro nth-value (n form &environment env)
  "Evaluate FORM and return the Nth value (zero based)
 without consing a temporary list of values."
  ;; FIXME: The above is true, if slightly misleading.  The
  ;; MULTIPLE-VALUE-BIND idiom [ as opposed to MULTIPLE-VALUE-CALL
  ;; (LAMBDA (&REST VALUES) (NTH N VALUES)) ] does indeed not cons at
  ;; runtime.  However, for large N (say N = 200), COMPILE on such a
  ;; form will take longer than can be described as adequate, as the
  ;; optional dispatch mechanism for the M-V-B gets increasingly
  ;; hairy.
  (let ((val (and (sb-xc:constantp n env) (constant-form-value n env))))
    (if (and (integerp val) (<= 0 val (or #+(or x86-64 arm64 riscv) ;; better DEFAULT-UNKNOWN-VALUES
                                          1000
                                          10))) ; Arbitrary limit.
        (let ((dummy-list (make-gensym-list val))
              (keeper (sb-xc:gensym "KEEPER")))
          `(multiple-value-bind (,@dummy-list ,keeper) ,form
             (declare (ignore ,@dummy-list))
             ,keeper))
      ;; &MORE conversion handily deals with non-constant N,
      ;; avoiding the unstylish practice of inserting FORM into the
      ;; expansion more than once to pick off a few small values.
      ;; This is not as good as above, because it uses TAIL-CALL-VARIABLE.
        `(multiple-value-call
             (lambda (n &rest list) (nth (truly-the index n) list))
           (the index ,n) ,form))))

(sb-xc:defmacro declaim (&rest specs)
  "DECLAIM Declaration*
  Do a declaration or declarations for the global environment."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     ,@(mapcar (lambda (spec)
                 `(sb-c::%proclaim ',spec (sb-c:source-location)))
               specs)))

;; Avoid unknown return values in emitted code for PRINT-UNREADABLE-OBJECT
(sb-xc:proclaim '(ftype (sfunction (t t t &optional t) null)
                        %print-unreadable-object))
(sb-xc:defmacro print-unreadable-object ((object stream &key type identity)
                                             &body body)
  "Output OBJECT to STREAM with \"#<\" prefix, \">\" suffix, optionally
  with object-type prefix and object-identity suffix, and executing the
  code in BODY to provide possible further output."
  ;; Note: possibly out-of-order keyword argument evaluation.
  ;; But almost always the :TYPE and :IDENTITY are each literal T or NIL,
  ;; and so the LOGIOR expression reduces to a fixed value from 0 to 3.
  (let ((call `(%print-unreadable-object
                ,object ,stream (logior (if ,type 1 0) (if ,identity 2 0)))))
    (if body
        (let ((fun (make-symbol "THUNK")))
          `(dx-flet ((,fun () ,@body)) (,@call #',fun)))
        call)))

(sb-xc:defmacro ignore-errors (&rest forms)
  "Execute FORMS handling ERROR conditions, returning the result of the last
  form, or (VALUES NIL the-ERROR-that-was-caught) if an ERROR was handled."
  `(handler-case (progn ,@forms)
     (error (condition) (values nil condition))))

;; A macroexpander helper. Not sure where else to put this.
(defun funarg-bind/call-forms (funarg arg-forms)
  (if (typep funarg
             '(or (cons (eql function) (cons (satisfies legal-fun-name-p) null))
                  (cons (eql quote) (cons symbol null))
                  (cons (eql lambda))))
      (values nil `(funcall ,funarg . ,arg-forms))
    (let ((fn-sym (sb-xc:gensym))) ; for ONCE-ONLY-ish purposes
      (values `((,fn-sym (%coerce-callable-to-fun ,funarg)))
              `(sb-c::%funcall ,fn-sym . ,arg-forms)))))

;;; Ordinarily during self-build, nothing would need this macro except the
;;; calls in src/code/list, and src/code/seq.
;;; However, if cons profiling is enbled, then all calls to COPY-LIST
;;; transform into the macro, so it must be available early.
(sb-xc:defmacro copy-list-macro (input &key check-proper-list)
  ;; Unless CHECK-PROPER-LIST is true, the list is copied correctly
  ;; even if the list is not terminated by NIL. The new list is built
  ;; by CDR'ing SPLICE which is always at the tail of the new list.
  (with-unique-names (orig copy splice cell)
    ;; source transform gave input the ONCE-ONLY treatment already.
    `(when ,input
       (let ((,copy (list (car ,input))))
         (do ((,orig (cdr ,input) (cdr ,orig))
              (,splice ,copy
                       (let ((,cell (list (car ,orig))))
                         (rplacd (truly-the cons ,splice) ,cell)
                         ,cell)))
           (,@(if check-proper-list
                  `((endp ,orig))
                  `((atom ,orig)
                    ;; always store the CDR even if NIL. A blind write
                    ;; is cheaper than a branch around a write.
                    (rplacd (truly-the cons ,splice) ,orig)))
            ,copy))))))
