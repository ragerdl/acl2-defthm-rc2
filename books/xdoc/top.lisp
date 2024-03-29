; XDOC Documentation System for ACL2
; Copyright (C) 2009-2011 Centaur Technology
;
; Contact:
;   Centaur Technology Formal Verification Group
;   7600-C N. Capital of Texas Highway, Suite 300, Austin, TX 78731, USA.
;   http://www.centtech.com/
;
; License: (An MIT/X11-style license)
;
;   Permission is hereby granted, free of charge, to any person obtaining a
;   copy of this software and associated documentation files (the "Software"),
;   to deal in the Software without restriction, including without limitation
;   the rights to use, copy, modify, merge, publish, distribute, sublicense,
;   and/or sell copies of the Software, and to permit persons to whom the
;   Software is furnished to do so, subject to the following conditions:
;
;   The above copyright notice and this permission notice shall be included in
;   all copies or substantial portions of the Software.
;
;   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;   DEALINGS IN THE SOFTWARE.
;
; Original author: Jared Davis <jared@centtech.com>


; top.lisp -- most end users should include this book directly.  If you are
; new to xdoc, you can try running:
;
;  (include-book "xdoc/top" :dir :system)
;  :xdoc xdoc

(in-package "XDOC")
(include-book "base")
(include-book "book-thms")

(defmacro colon-xdoc-init ()
  '(with-output :off (summary event observation)
     (make-event
      (if (not (cdr (assoc 'colon-xdoc-support-loaded (table-alist 'xdoc (w state)))))
        `(progn
           (include-book ;; newlines to fool dependency scanner
            "xdoc/defxdoc-raw" :dir :system :ttags :all)
           (include-book
            "xdoc/topics" :dir :system)
           (include-book
            "xdoc/display" :dir :system)
           (encapsulate ()
            (local (xdoc-quiet)) ;; Suppress warnings when just using :xdoc (or :doc) 
            (local (set-inhibit-warnings "Documentation"))
            (import-acl2doc))
           (table xdoc 'colon-xdoc-support-loaded t))
        '(value-triple :invisible)))))

(defmacro xdoc (name)
  (declare (xargs :guard (or (symbolp name)
                             (and (quotep name)
                                  (symbolp (unquote name))))))
  (let ((name (if (symbolp name)
                  name
                (unquote name))))
    `(with-output :off (summary event)
       (progn
         (colon-xdoc-init)
         (make-event
          (b* (((mv all-xdoc-topics state) 
                (with-guard-checking t (all-xdoc-topics state)))
               ((mv & & state) (colon-xdoc-fn ',name all-xdoc-topics state)))
            (value '(value-triple :invisible))))))))

; Hijack ACL2's :doc keyword and replace it with :xdoc

(add-ld-keyword-alias! :doc '(1 xdoc))

(defmacro xdoc-extend (name long)
  `(table xdoc 'doc
          (let* ((all-topics   (xdoc::get-xdoc-table world))
                 (old-topic    (xdoc::find-topic ',name all-topics))
                 (long         (or ,long "")))
            (cond ((not old-topic)
                   (prog2$
                    (er hard? 'xdoc-extend "Topic ~x0 wasn't found." ',name)
                    all-topics))
                   (t
                    (let* ((other-topics (remove-equal old-topic all-topics))
                           (old-long     (or (cdr (assoc :long old-topic)) ""))
                           (new-long     (concatenate 'string old-long long))
                           (new-topic    (acons :long new-long
                                                (delete-assoc :long old-topic))))
                      (cons new-topic other-topics)))))))

(defmacro xdoc-prepend (name long)
  `(table xdoc 'doc
          (let* ((all-topics   (xdoc::get-xdoc-table world))
                 (old-topic    (xdoc::find-topic ',name all-topics))
                 (long         (or ,long "")))
            (cond ((not old-topic)
                   (er hard? 'xdoc-prepend "Topic ~x0 wasn't found." ',name))
                  (t
                   (let* ((other-topics (remove-equal old-topic all-topics))
                          (old-long     (cdr (assoc :long old-topic)))
                          (new-long     (concatenate 'string long old-long))
                          (new-topic    (acons :long new-long
                                               (delete-assoc :long old-topic))))
                     (cons new-topic other-topics)))))))

(defmacro order-subtopics (name order)
  `(table xdoc 'doc
          (let* ((all-topics (xdoc::get-xdoc-table world))
                 (old-topic  (xdoc::find-topic ',name all-topics))
                 (order      ',order))
            (cond ((not old-topic)
                   (er hard? 'order-subtopics "Topic ~x0 wasn't found." ',name))
                  ((not (symbol-listp order))
                   (er hard? 'order-subtopics "Subtopics are not a symbol list: ~x0" order))
                  (t
                    (let* ((other-topics (remove-equal old-topic all-topics))
                           (new-topic    (acons :suborder order
                                                (delete-assoc :suborder old-topic))))
                      (cons new-topic other-topics)))))))

(defund extract-keyword-from-args (kwd args)
  (declare (xargs :guard (keywordp kwd)))
  (cond ((atom args)
         nil)
        ((eq (car args) kwd)
         (if (consp (cdr args))
             (cons (car args)
                   (cadr args))
           (er hard? 'extract-keyword-from-args
               "Expected something to follow ~s0." kwd)))
        (t
         (extract-keyword-from-args kwd (cdr args)))))

(defund throw-away-keyword-parts (args)
  (declare (xargs :guard t))
  (cond ((atom args)
         nil)
        ((keywordp (car args))
         (throw-away-keyword-parts (if (consp (cdr args))
                                       (cddr args)
                                     (er hard? 'throw-away-keyword-parts
                                         "Expected something to follow ~s0."
                                         (car args)))))
        (t
         (cons (car args)
               (throw-away-keyword-parts (cdr args))))))

(defun bar-escape-chars (x)
  (declare (xargs :mode :program))
  (cond ((atom x)
         nil)
        ((eql (car x) #\|)
         (list* #\\ #\| (bar-escape-chars (cdr x))))
        (t
         (cons (car x) (bar-escape-chars (cdr x))))))

(defun bar-escape-string (x)
  (declare (xargs :mode :program))
  (coerce (bar-escape-chars (coerce x 'list)) 'string))

(defun full-escape-symbol (x)
  (declare (xargs :mode :program))
  (concatenate 'string "|" (bar-escape-string (symbol-package-name x)) "|::|"
               (bar-escape-string (symbol-name x)) "|"))

(defun formula-info-to-defs1 (entries)
  ;; See misc/book-thms.lisp.  Entries should be the kind of structure that
  ;; new-formula-info produces.  We turn it into a list of "@(def fn)" entries.
  ;; This is a hack.  We probably want something smarter.
  (declare (xargs :mode :program))
  (cond ((atom entries)
         nil)
        ((and (consp (car entries))
              (symbolp (caar entries)))
         (cons (concatenate 'string "@(def " (full-escape-symbol (caar entries)) ")")
               (formula-info-to-defs1 (cdr entries))))
        (t
         (formula-info-to-defs1 (cdr entries)))))

(defun join-strings (strs sep)
  (declare (xargs :mode :program))
  (cond ((atom strs)
         "")
        ((atom (cdr strs))
         (car strs))
        (t
         (concatenate 'string (car strs) sep (join-strings (cdr strs) sep)))))

(defun formula-info-to-defs (headerp entries)
  ;; BOZO make this nicer
  (declare (xargs :mode :program))
  (let ((strs (formula-info-to-defs1 entries)))
    (if strs
        (concatenate 'string
                     (if headerp "<h3>Definitions and Theorems</h3>" "")
                     (join-strings strs (coerce (list #\Newline) 'string)))
      "")))

(defun defsection-fn (wrapper ; (encapsulate nil) or (progn)
                      name args)
  (declare (xargs :mode :program))
  (let* ((parents     (cdr (extract-keyword-from-args :parents args)))
         (short       (cdr (extract-keyword-from-args :short args)))
         (long        (cdr (extract-keyword-from-args :long args)))
         (extension   (cdr (extract-keyword-from-args :extension args)))
         (defxdoc-p   (and (not extension)
                           (or parents short long)))
         (autodoc-arg (extract-keyword-from-args :autodoc args))
         (autodoc-p   (and (or defxdoc-p extension)
                           (or (not autodoc-arg)
                               (cdr autodoc-arg))))
         (new-args (throw-away-keyword-parts args)))
    (cond ((and extension
                (or parents short))
           (er hard? 'defsection-fn "When using :extension, you cannot ~
                  give a :parents or :short field."))

          ((and extension
                (not (symbolp extension)))
           (er hard? 'defsection-fn "Expected a single symbol for :extension, ~
                                     but was given ~x0." extension))

          ((not autodoc-p)
           `(with-output
              :stack :push
              :off :all
              :on error  ;; leave errors on, or you can think forms succeeded when they didn't.
              (progn
                ,@(and defxdoc-p
                       `((defxdoc ,name
                           :parents ,parents
                           :short ,short
                           :long ,long)))
                (with-output :stack :pop
                  (,@wrapper
                   ;; A silly value-triple so that an empty defsection is okay.
                   (value-triple :invisible)
                   . ,new-args))
                ,@(and extension
                       long
                       `(xdoc-extend ,extension ,long)))))

          (t
           ;; Fancy autodoc stuff.
           (let ((marker `(table acl2::intro-table :mark ',name)))
             `(with-output
                :stack :push
                :off :all
                :on error
                (progn
                  ,marker
                  (with-output :stack :pop
                    (,@wrapper
                     ;; A silly value-triple so that an empty defsection is okay.
                     (value-triple :invisible)
                     . ,new-args))
                  (make-event
                   (let* ((name      ',name)
                          (parents   ',parents)
                          (short     ',short)
                          (extension ',extension)
                          (wrld      (w state))
                          (trips     (acl2::reversed-world-since-event wrld ',marker nil))
                          (info      (reverse (acl2::new-formula-info trips wrld nil)))
                          (autodoc   (formula-info-to-defs (not extension) info))
                          (long      (concatenate 'string
                                                  ',(or long "")
                                                  (coerce (list #\Newline #\Newline) 'string)
                                                  autodoc)))
                     (if extension
                         `(xdoc-extend ,extension ,long)
                       `(defxdoc ,name
                          :parents ,parents
                          :short ,short
                          :long ,long))))
                  (value-triple ',name))))))))

(defmacro defsection (name &rest args)
  (declare (xargs :guard (symbolp name)))
  (defsection-fn '(encapsulate nil) name args))

(defmacro defsection-progn (name &rest args)
  (declare (xargs :guard (symbolp name)))
  (defsection-fn '(progn) name args))


;; Moved from cutil/deflist for greater availability
(defsection mksym

  (defun concatenate-symbol-names (x)
    (declare (xargs :guard (symbol-listp x)))
    (if (consp x)
        (acl2::concatenate 'string
                           (symbol-name (car x))
                           (concatenate-symbol-names (cdr x)))
      ""))

  (defmacro mksym (&rest args)
    `(intern-in-package-of-symbol
      (concatenate-symbol-names (list ,@args))
      mksym-package-symbol)))

; Moved from acl2-doc.lisp to make it more widely available
(defmacro defpointer (from to &optional keyword-p)

; Examples:

; (defpointer &allow-other-keys macro-args) expands to:

; (defxdoc &allow-other-keys
;   :parents (pointers)
;   :short "See @(see macro-args).")

; (defpointer guard-hints xargs t) expands to:

; (defxdoc &allow-other-keys
;   :parents (pointers)
;   :short "See @(see xargs) for keyword :guard-hints.")

  `(defxdoc ,from
     :parents (pointers)
     :short ,(concatenate 'string
                          "See @(see "
                          (acl2::string-downcase (symbol-name to))
                          ")"
                          (if keyword-p
                              (concatenate 'string
                                           " for keyword @(':"
                                           (acl2::string-downcase (symbol-name from))
                                           "').")
                            "."))))
