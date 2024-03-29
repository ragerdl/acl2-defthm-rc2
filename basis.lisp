; ACL2 Version 6.5 -- A Computational Logic for Applicative Common Lisp
; Copyright (C) 2014, Regents of the University of Texas

; This version of ACL2 is a descendent of ACL2 Version 1.9, Copyright
; (C) 1997 Computational Logic, Inc.  See the documentation topic NOTE-2-0.

; This program is free software; you can redistribute it and/or modify
; it under the terms of the LICENSE file distributed with ACL2.

; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; LICENSE for more details.

; Written by:  Matt Kaufmann               and J Strother Moore
; email:       Kaufmann@cs.utexas.edu      and Moore@cs.utexas.edu
; Department of Computer Science
; University of Texas at Austin
; Austin, TX 78712 U.S.A.

; When we are ready to verify termination in this and later files, we should
; consider changing null to endp in a number of functions.

(in-package "ACL2")

; We need to have state globals bound for prin1$ etc. to work, because of calls
; of with-print-controls.  We may also need the dolist form below for tracing,
; which uses current-package for printing and current-acl2-world for
; current-acl2-world suppression.  State globals such as 'compiler-enabled,
; whose value depends on the host Common Lisp implementation, are initialized
; here rather than in *initial-global-table*, so that the value of any defconst
; (such as *initial-global-table*) is independent of the host Common Lisp
; implementation.  That is important to avoid trivial soundness bugs based on
; variance of a defconst value from one underlying Lisp to another.

#-acl2-loop-only
(initialize-state-globals)

(defun enforce-redundancy-er-args (event-form-var wrld-var)
  (list "Enforce-redundancy is active; see :DOC set-enforce-redundancy and ~
         see :DOC redundant-events.  However, the following event ~@0:~|~%~x1"
        `(if (and (symbolp (cadr ,event-form-var))
                  (decode-logical-name (cadr ,event-form-var) ,wrld-var))
             "conflicts with an existing event of the same name"
           "is not redundant")
        event-form-var))

(defmacro enforce-redundancy (event-form ctx wrld form)
  (let ((var 'redun-check-var))
    `(let ((,var (and (not (eq (ld-skip-proofsp state)
                               'include-book))
                      (cdr (assoc-eq :enforce-redundancy
                                     (table-alist 'acl2-defaults-table
                                                  ,wrld))))))
       (cond ((eq ,var t)
              (check-vars-not-free
               (,var)
               (er soft ,ctx
                   ,@(enforce-redundancy-er-args
                      event-form wrld))))
             (t (pprogn (cond (,var (check-vars-not-free
                                     (,var)
                                     (warning$ ,ctx "Enforce-redundancy"
                                               ,@(enforce-redundancy-er-args
                                                  event-form wrld))))
                              (t state))
                        (check-vars-not-free
                         (,var)
                         ,form)))))))

; Essay on Wormholes

; Once upon a time (Version  3.6 and earlier) the wormhole function had a
; pseudo-flg argument which allowed the user a quick way to determine whether
; it was appropriate to incur the expense of going into the wormhole.  The idea
; was that the form could have one a free var in it, wormhole-output, and that
; when it was evaluated in raw Lisp that variable was bound to the last value
; returned by the wormhole.  Since wormhole always returned nil anyway, this
; screwy semantics didn't matter.  However, it was implemented in such a way
; that a poorly constructed pseudo-flg could survive guard verification and yet
; cause a hard error at runtime because during guard verification
; wormhole-output was bound to NIL but in actual evaluation it was entirely
; under the control of the wormhole forms.

; To fix this we have introduced wormhole-eval.  It takes two important
; arguments, the name of the wormhole and a lambda expression.  Both must be
; quoted.  The lambda may have at most one argument but the body may contain
; any variables available in the environment of the wormhole-eval call.  (A
; third argument to wormhole-eval is an arbitrary form that uses all the free
; vars of the lambda, thus insuring that translate will cause an error if the
; lambda uses variables unavailble in the context.)  The body of the lambda
; must be a single-valued, non-state, non-stobj term.

; The idea is that the lambda expression is applied to the last value of the
; wormhole output and its value is assigned as the last value of the wormhole
; output.  Wormhole-eval always returns nil.  Translation of a wormhole-eval
; call enforces these restrictions.  Furthermore, it translates the body of the
; lambda (even though the lambda is quoted).  This is irrelevant since the
; wormhole-eval returns nil regardless of the lambda expression supplied.
; Similarly, translation computes an appropriate third argument to use all the
; free vars, so the user may just write nil there and a suitable form is
; inserted by translate.

; We arrange for wormhole-eval to be a macro in raw lisp that really does what
; is said above.

; To make it bullet-proof, when we generate guard clauses we go inside the
; lambda, generating a new variable symbol to use in place of the lambda formal
; denoting the last value of the wormhole output.  Thus, if guard clauses can be
; verified, it doesn't matter what the wormhole actually returns as its value.

; Ev-rec, the interpreter for terms, treats wormhole-eval specially in the
; expected way, as does oneify.  Thus, both interpreted and compiled calls of
; wormhole-eval are handled, and guard violations are handled politely.

; Now, how does this allow us to fix the wormhole pseudo-flg problem?

; The hidden global variable in Lisp used to record the status of the various
; wormholes is called *wormhole-status-alist*.  The entry in this alist for
; a particular wormhole will be called the wormhole's ``status.''  The lambda
; expression in wormhole-eval maps the wormhole's status to a new status.

; The status of a wormhole is supposed to be a cons whose car is either :ENTER
; or :SKIP.  However, in the absence of verifying the guards on the code inside
; wormholes and in light of the fact that users can set the status by
; manipulating wormhole-status in the wormhole it is hard to insure that the
; status is always as supposed.  So we code rather defensively.

; When the ``function'' wormhole is called it may or may not actually enter a
; wormhole.  ``Entering'' the wormhole means invoking the form on the given
; input, inside a side-effects undoing call of ld.  That, in turn, involves
; setting up the ld specials and then reading, translating, and evaluating
; forms.  Upon exit, cleanup must be done.  So entering is expensive.

; Whether it enters the wormhole or not depends on the wormhole's status, and
; in particular it depends on what we call the wormhole's ``entry code''
; computed from the status as follows.

; If the wormhole's status statisfies wormhole-statusp then the situation is
; simple: wormhole enters the wormhole if the status is :ENTER and doesn't if
; the status is :SKIP.  But we compute the entry code defensively: the entry
; code is :SKIP if and only if the wormhole's status is a cons whose car is
; :SKIP.  Otherwise, the entry code is :ENTER.

; If we enter the wormhole, we take the wormhole input argument and stuff it
; into (@ wormhole-input), allowing the user to see it inside the ld code.  We
; take the wormhole status and stuff it into (@ wormhole-status), allowing the
; user to see it and probably change it with (assign wormhole-status...).  When
; we exit ld, we take (@ wormhole-status) and put it back into the hidden
; *wormhole-status-alist*.

; One subtlety arises: How to make wormholes re-entrant...  The problem is that
; sometimes the current status is in the hidden alist and other times it is in
; (@ wormhole-status).  So when we try to enter a new wormhole from within a
; wormhole -- which always happens by calling wormhole-eval -- the first thing
; we do is stuff the current (@ wormhole-status) into the hidden
; *wormhole-status-alist*.  This means that the lambda expression for the new
; entrance is applied, it is applied to the ``most recent'' value of the status
; of that particular wormhole.  The natural undoing of wormhole effects
; implements the restoration of (@ wormhole-status) upon exit from the
; recursive wormhole.

; If we wanted to convert our system code to logic mode we would want to verify
; the guards of the lambda bodies and the wormhole-status after ld.  See the
; comment in push-accp.  Here is a proposal for how to do that.  First, insist
; that wormhole names are symbols.  Indeed, they must be one argument,
; guard-verified Boolean functions.  The guard for a call of wormhole-eval on a
; wormhole named foo should include the conjunct (foo nil) to insure that the
; initial value of the status is acceptable.  The guard on the body of (lambda
; (whs) body) should be extended to include the hypothesis that (foo whs) is
; true and that (foo whs) --> (foo body) is true.  We should then change
; wormhole so that if it calls ld it tests foo at runtime after the ld returns
; so we know that the final status satisfies foo.  If we do this we can safely
; assume that every status seen by a lambda body in wormhole-eval will satisfy
; the foo invariant.

(defun wormhole-statusp (whs)
  (declare (xargs :mode :logic :guard t))
  (or (equal whs nil)
      (and (consp whs)
           (or (eq (car whs) :ENTER)
               (eq (car whs) :SKIP)))))

(defun wormhole-entry-code (whs)

; Keep this function in sync with the inline code in wormhole1.

  (declare (xargs :mode :logic :guard t))
  (if (and (consp whs)
           (eq (car whs) :SKIP))
      :SKIP
      :ENTER))

(defun wormhole-data (whs)
  (declare (xargs :mode :logic :guard t))
  (if (consp whs)
      (cdr whs)
      nil))

(defun set-wormhole-entry-code (whs code)
  (declare (xargs :mode :logic
                  :guard (or (eq code :ENTER)
                             (eq code :SKIP))))
  (if (consp whs)
      (if (eq (car whs) code)
          whs
          (cons code (cdr whs)))
      (if (eq code :enter)
          whs
          (cons :skip whs))))

(defun set-wormhole-data (whs data)
  (declare (xargs :mode :logic :guard t))
  (if (consp whs)
      (if (equal (cdr whs) data)
          whs
          (cons (car whs) data))
      (cons :enter data)))

(defun make-wormhole-status (old-status new-code new-data)
  (declare (xargs :mode :logic
                  :guard (or (eq new-code :ENTER)
                             (eq new-code :SKIP))))
  (if (consp old-status)
      (if (and (eq new-code (car old-status))
               (equal new-data (cdr old-status)))
          old-status
          (cons new-code new-data))
      (cons new-code new-data)))

; (defthm wormhole-status-guarantees
;   (if (or (eq code :enter)
;           (eq code :skip))
;       (and (implies (wormhole-statusp whs)
;                     (wormhole-statusp (set-wormhole-entry-code whs code)))
;            (implies (wormhole-statusp whs)
;                     (wormhole-statusp (set-wormhole-data whs data)))
;            (equal (wormhole-entry-code (set-wormhole-entry-code whs code))
;                   code)
;            (equal (wormhole-data (set-wormhole-data whs data))
;                   data)
;            (implies (wormhole-statusp whs)
;                     (equal (wormhole-data (set-wormhole-entry-code whs code))
;                            (wormhole-data whs)))
;            (implies (wormhole-statusp whs)
;                     (equal (wormhole-entry-code
;                             (set-wormhole-data whs data))
;                            (wormhole-entry-code whs)))
;            (implies (wormhole-statusp whs)
;                     (wormhole-statusp (make-wormhole-status whs code data)))
;            (equal (wormhole-entry-code (make-wormhole-status whs code data))
;                   code)
;            (equal (wormhole-data (make-wormhole-status whs code data))
;                   data))
;       t)
;   :rule-classes nil)
;
; (verify-guards wormhole-status-guarantees)

; In particular, given a legal code, set-wormhole-entry-code preserves
; wormhole-statusp and always returns an object with the given entry code
; (whether the status was well-formed or not).  Furthermore, the guards on
; these functions are verified.  Thus, they can be called safely even if the
; user has messed up our wormhole status.  Of course, if the user has messed up
; the status, there is no guarantee about what happens inside the wormhole.

(defun tree-occur-eq (x y)

; Does symbol x occur in the cons tree y?

  (declare (xargs :guard (symbolp x)))
  (cond ((consp y)
         (or (tree-occur-eq x (car y))
             (tree-occur-eq x (cdr y))))
        (t (eq x y))))

#+acl2-loop-only
(defun wormhole-eval (qname qlambda free-vars)

; A typical call of this function is
; (wormhole-eval 'my-wormhole
;                '(lambda (output) (p x y output))
;                (list x y))

; And the pragmatic semantics is that the lambda expression is applied to the
; last output of the wormhole my-wormhole, the result of of the application is
; stuffed back in as the last output, and the function logically returns nil.
; Note that free vars in the lambda must listed.  This is so that the free vars
; of this wormhole-eval expression consists of the free vars of the lambda,
; even though the lambda appears quoted.  Translate automatically replaces the
; lambda expression constant by the translated version of that same constant,
; and it replaces the supposed list of free vars by the actual free vars.  So
; in fact the user calling wormhole-eval can just put nil in the free-vars arg
; and let translate fill it in.  Translate can mangle the arguments of
; wormhole-eval because it always returns nil, regardless of its arguments.

; The guard is declared below to be t but actually we compute the guard for the
; body of the quoted lambda, with some fiddling about the bound variable.

  (declare (xargs :mode :logic
                  :guard t)
           (ignore qname qlambda free-vars))


  nil)

(deflock *wormhole-lock*)

#-acl2-loop-only
(defmacro wormhole-eval (qname qlambda free-vars)
  (declare (xargs :guard t))

; All calls of wormhole-eval that have survived translation are of a special
; form.  Qname is a quoted object (used as the name of a wormhole), and qlambda
; is of one of the two forms:

; (i)  (quote (lambda (whs) body)), or
; (ii) (quote (lambda ()    body))

; where whs (``wormhole status'') is a legal variable symbol, body is a fully
; translated term that may involve whs and other variables which returns one
; result.  We furthermore know that the free vars in the lambda are the free
; vars of the term free-vars, which is typically just a list-expression of
; variable names supplied by translate.  Finally, we know that whs appears as
; the lambda formal iff it is used in body.

; Wormholes may have arbitrary objects for names, so qname is not necessarily a
; quoted symbol.  This may be the first entry into the wormhole of that name,
; in which case the most recent output of the wormhole is understood to be nil.

; Logically this function always returns nil.  Actually, it applies the lambda
; expression to either (i) ``the most recent output'' of the named wormhole or
; (ii) no arguments, appropriately, and stores the result as the most recent
; output, and then returns nil.

  (let* ((whs (if (car (cadr (cadr qlambda)))
                  (car (cadr (cadr qlambda))) ; Case (i)
                (gensym)))                    ; Case (ii)
         (val (gensym))
         (form

; The code we lay down is the same in both cases, because we use the variable whs to
; store the old value of the status to see whether it has changed.  But we have
; to generate a name if one isn't supplied.

          `(progn
             (cond (*wormholep*
                    (setq *wormhole-status-alist*
                          (put-assoc-equal
                           (f-get-global 'wormhole-name
                                         *the-live-state*)
                           (f-get-global 'wormhole-status
                                         *the-live-state*)
                           *wormhole-status-alist*))))
             (let* ((*wormholep* t)
                    (,whs (cdr (assoc-equal ,qname *wormhole-status-alist*)))
                    (,val ,(caddr (cadr qlambda))))
               (or (equal ,whs ,val)
                   (setq *wormhole-status-alist*
                         (put-assoc-equal ,qname ,val *wormhole-status-alist*)))
               nil))))
    (cond ((tree-occur-eq :no-wormhole-lock free-vars)
           form)
          (t `(with-wormhole-lock ,form)))))

(defmacro wormhole (name entry-lambda input form
                         &key
                         (current-package 'same current-packagep)
                         (ld-skip-proofsp 'same ld-skip-proofspp)
                         (ld-redefinition-action 'save ld-redefinition-actionp)
                         (ld-prompt ''wormhole-prompt)
                         (ld-missing-input-ok 'same ld-missing-input-okp)
                         (ld-pre-eval-filter 'same ld-pre-eval-filterp)
                         (ld-pre-eval-print 'same ld-pre-eval-printp)
                         (ld-post-eval-print 'same ld-post-eval-printp)
                         (ld-evisc-tuple 'same ld-evisc-tuplep)
                         (ld-error-triples 'same ld-error-triplesp)
                         (ld-error-action 'same ld-error-actionp)
                         (ld-query-control-alist 'same ld-query-control-alistp)
                         (ld-verbose 'same ld-verbosep))
  `(with-wormhole-lock
    (prog2$
     (wormhole-eval ,name ,entry-lambda

; It is probably harmless to allow a second lock under the one above, but there
; is no need, so we avoid it.

                    :no-wormhole-lock)
     (wormhole1
      ,name
      ,input
      ,form
      (list
       ,@(append
          (if current-packagep
              (list `(cons 'current-package ,current-package))
            nil)
          (if ld-skip-proofspp
              (list `(cons 'ld-skip-proofsp ,ld-skip-proofsp))
            nil)
          (if ld-redefinition-actionp
              (list `(cons 'ld-redefinition-action
                           ,ld-redefinition-action))
            nil)
          (list `(cons 'ld-prompt ,ld-prompt))
          (if ld-missing-input-okp
              (list `(cons 'ld-missing-input-ok ,ld-missing-input-ok))
            nil)
          (if ld-pre-eval-filterp
              (list `(cons 'ld-pre-eval-filter ,ld-pre-eval-filter))
            nil)
          (if ld-pre-eval-printp
              (list `(cons 'ld-pre-eval-print ,ld-pre-eval-print))
            nil)
          (if ld-post-eval-printp
              (list `(cons 'ld-post-eval-print ,ld-post-eval-print))
            nil)
          (if ld-evisc-tuplep
              (list `(cons 'ld-evisc-tuple ,ld-evisc-tuple))
            nil)
          (if ld-error-triplesp
              (list `(cons 'ld-error-triples ,ld-error-triples))
            nil)
          (if ld-error-actionp
              (list `(cons 'ld-error-action ,ld-error-action))
            nil)
          (if ld-query-control-alistp
              (list `(cons 'ld-query-control-alist ,ld-query-control-alist))
            nil)
          (if ld-verbosep
              (list `(cons 'ld-verbose ,ld-verbose))
            nil)))))))

(defun global-set (var val wrld)
  (declare (xargs :guard (and (symbolp var)
                              (plist-worldp wrld))))
  (putprop var 'global-value val wrld))

(defun defabbrev1 (lst)
  (declare (xargs :guard (true-listp lst)))
  (cond ((null lst) nil)
        (t (cons (list 'list (list 'quote (car lst)) (car lst))
                 (defabbrev1 (cdr lst))))))

(defun legal-variable-or-constant-namep (name)

; This function checks the syntax of variable or constant name
; symbols.  In all cases, name must be a symbol that is not in the
; keyword package or among *common-lisp-specials-and-constants*
; (except t and nil), or in the main Lisp package but outside
; *common-lisp-symbols-from-main-lisp-package*, and that does not
; start with an ampersand.  The function returns 'constant, 'variable,
; or nil.

; WARNING: T and nil are legal-variable-or-constant-nameps
; because we want to allow their use as constants.

; We now allow some variables (but still no constants) from the main Lisp
; package.  See *common-lisp-specials-and-constants*.  The following note
; explains why we have been cautious here.

; Historical Note

; This package restriction prohibits using some very common names as
; variables or constants, e.g., MAX and REST.  Why do we do this?  The
; reason is that there are a few such symbols, such as
; LAMBDA-LIST-KEYWORDS, which if bound or set could cause real
; trouble.  Rather than attempt to identify all of the specials of
; CLTL that are prohibited as ACL2 variables, we just prohibit them
; all.  One might be reminded of Alexander cutting the Gordian Knot.
; We could spend a lot of time unravelling complex questions about
; specials in CLTL or we can get on with it.  When ACL2 prevents you
; from using REST as an argument, you should see the severed end of a
; once tangled rope.

; For example, akcl and lucid (and others perhaps) allow you to define
; (defun foo (boole-c2) boole-c2) but then (foo 3) causes an error.
; Note that boole-c2 is recognized as special (by
; system::proclaimed-special-p) in lucid, but not in akcl (by
; si::specialp); in fact it's a constant in both.  Ugh.

; End of Historical Note.

  (and (symbolp name)
       (cond
        ((or (eq name t) (eq name nil))
         'constant)
        (t (let ((p (symbol-package-name name)))
             (and (not (equal p "KEYWORD"))
                  (let ((s (symbol-name name)))
                    (cond
                     ((and (not (= (length s) 0))
                           (eql (char s 0) #\*)
                           (eql (char s (1- (length s))) #\*))

; It was an oversight that a symbol with a symbol-name of "*" has always been
; considered a constant rather than a variable.  The intention was to view "*"
; as a delimeter -- thus, even "**" is probably OK for a constant since the
; empty string is delimited.  But it doesn't seem important to change this
; now.  If we do make such a change, consider the following (at least).

; - It will be necessary to update :doc defconst.

; - Fix the error message for, e.g., (defconst foo::* 17), so that it doesn't
;   say "does not begin and end with the character *".

; - Make sure the error message is correct for (defun foo (*) *).  It should
;   probably complain about the main Lisp package, not about "the syntax of a
;   constant".

                      (if (equal p *main-lisp-package-name*)
                          nil
                        'constant))
                     ((and (not (= (length s) 0))
                           (eql (char s 0) #\&))
                      nil)
                     ((equal p *main-lisp-package-name*)
                      (and (not (member-eq
                                 name
                                 *common-lisp-specials-and-constants*))
                           (member-eq
                            name
                            *common-lisp-symbols-from-main-lisp-package*)
                           'variable))
                     (t 'variable)))))))))

(defun legal-constantp1 (name)

; This function should correctly distinguish between variables and
; constants for symbols that are known to satisfy
; legal-variable-or-constant-namep.  Thus, if name satisfies this
; predicate then it cannot be a variable.

  (declare (xargs :guard (symbolp name)))
  (or (eq name t)
      (eq name nil)
      (let ((s (symbol-name name)))
        (and (not (= (length s) 0))
             (eql (char s 0) #\*)
             (eql (char s (1- (length s))) #\*)))))

(defun tilde-@-illegal-variable-or-constant-name-phrase (name)

; Assume that legal-variable-or-constant-namep has failed on name.
; We return a phrase that when printed with ~@0 will complete the
; sentence "Variable names must ...".  Observe that the sentence
; could be "Constant names must ...".

  (cond ((not (symbolp name)) "be symbols")
        ((keywordp name) "not be in the KEYWORD package")
        ((and (legal-constantp1 name)
              (equal (symbol-package-name name) *main-lisp-package-name*))
         (cons "not be in the main Lisp package, ~x0"
               (list (cons #\0 *main-lisp-package-name*))))
        ((and (> (length (symbol-name name)) 0)
              (eql (char (symbol-name name) 0) #\&))
         "not start with ampersands")
        ((and (not (legal-constantp1 name))
              (member-eq name *common-lisp-specials-and-constants*))
         "not be among certain symbols from the main Lisp package, namely, the ~
          value of the list *common-lisp-specials-and-constants*")
        ((and (not (legal-constantp1 name))
              (equal (symbol-package-name name) *main-lisp-package-name*)
              (not (member-eq name *common-lisp-symbols-from-main-lisp-package*)))
         "either not be in the main Lisp package, or else must be among the ~
          imports into ACL2 from that package, namely, the list ~
          *common-lisp-symbols-from-main-lisp-package*")
        (t "be approved by LEGAL-VARIABLE-OR-CONSTANT-NAMEP and this ~
            one wasn't, even though it passes all the checks known to ~
            the diagnostic function ~
            TILDE-@-ILLEGAL-VARIABLE-OR-CONSTANT-NAME-PHRASE")))

(defun legal-constantp (name)

; A name may be declared as a constant if it has the syntax of a
; variable or constant (see legal-variable-or-constant-namep) and
; starts and ends with a *.

; WARNING: Do not confuse this function with defined-constant.

  (eq (legal-variable-or-constant-namep name) 'constant))

(defun defined-constant (name w)

; Name is a defined-constant if it has been declared with defconst.
; If name is a defined-constant then we can show that it satisfies
; legal-constantp, because when a name is declared as a constant we
; insist that it satisfy the syntactic check.  But there are
; legal-constantps that aren't defined-constants, e.g., any symbol
; that could be (but hasn't yet been) declared as a constant.  We
; check, below, that name is a symbolp just to guard the getprop.

; This function returns the quoted term that is the value of name, if
; name is a constant.  That result is always non-nil (it may be (quote
; nil) of course).

  (and (symbolp name)
       (getprop name 'const nil 'current-acl2-world w)))

(defun legal-variablep (name)

; Name may be used as a variable if it has the syntax of a variable
; (see legal-variable-or-constant-namep) and does not have the syntax of
; a constant, i.e., does not start and end with a *.

  (eq (legal-variable-or-constant-namep name) 'variable))

(defun genvar1 (pkg-witness char-lst avoid-lst cnt)

; This function generates a symbol in the same package as the symbol
; pkg-witness that is guaranteed to be a legal-variablep and not in avoid-lst.
; We form a symbol by concatenating char-lst and the decimal representation of
; the natural number cnt.  Observe the guard below.  Since guards are not
; checked in :program code, the user must ensure upon calling this
; function that pkg-witness is a symbol in some package other than the main
; lisp package or the keyword package and that char-lst is a list of characters
; not beginning with * or &.  Given that guard, there must exist a sufficiently
; large cnt to make our generated symbol be in the package of pkg-witness (a
; finite number of generated symbols might have been interned in one of the
; non-variable packages).

  (declare (xargs :guard (and (let ((p (symbol-package-name pkg-witness)))
                                (and (not (equal p "KEYWORD"))
                                     (not (equal p *main-lisp-package-name*))))
                              (consp char-lst)
                              (not (eql (car char-lst) #\*))
                              (not (eql (car char-lst) #\&)))))
  (let ((sym (intern-in-package-of-symbol
              (coerce
               (append char-lst
                       (explode-nonnegative-integer cnt 10 nil))
               'string)
              pkg-witness)))
    (cond ((or (member sym avoid-lst)

; The following call of legal-variablep could soundly be replaced by
; legal-variable-or-constant-namep, given the guard above, but we keep it
; as is for robustness.

               (not (legal-variablep sym)))
           (genvar1 pkg-witness char-lst avoid-lst (1+ cnt)))
          (t sym))))

(defun genvar (pkg-witness prefix n avoid-lst)

; This is THE function that ACL2 uses to generate new variable names.
; Prefix is a string and n is either nil or a natural number.  Together we
; call prefix and n the "root" of the variable we generate.

; We generate from prefix a legal variable symbol in the same package as
; pkg-witness that does not occur in avoid-lst.  If n is nil, we first try the
; symbol with symbol-name prefix first and otherwise suffix prefix with
; increasingly large naturals (starting from 0) to find a suitable variable.
; If n is non-nil it had better be a natural and we immediately begin trying
; suffixes from there.  Since no legal variable begins with #\* or #\&, we tack
; a #\V on the front of our prefix if prefix starts with one of those chars.
; If prefix is empty, we use "V".

; Note: This system will eventually contain a lot of code to generate
; "suggestive" variable names.  However, we make the convention that
; in the end every variable name generated is generated by this
; function.  Thus, all other code associated with variable name
; generation is heuristic if this one is correct.

  (let* ((pkg-witness (cond ((let ((p (symbol-package-name pkg-witness)))
                               (or (equal p "KEYWORD")
                                   (equal p *main-lisp-package-name*)))
; If pkg-witness is in an inappropriate package, we default it to the
; "ACL2" package.
                             'genvar)
                            (t pkg-witness)))
         (sym (if (null n) (intern-in-package-of-symbol prefix pkg-witness) nil))
         (cnt (if n n 0)))
    (cond ((and (null n)
                (legal-variablep sym)
                (not (member sym avoid-lst)))
           sym)
          (t (let ((prefix (coerce prefix 'list)))
               (cond ((null prefix) (genvar1 pkg-witness '(#\V) avoid-lst cnt))
                     ((and (consp prefix)
                           (or (eql (car prefix) #\*)
                               (eql (car prefix) #\&)))
                      (genvar1 pkg-witness (cons #\V prefix) avoid-lst cnt))
                     (t (genvar1 pkg-witness prefix avoid-lst cnt))))))))

(defun packn1 (lst)
  (declare (xargs :guard (good-atom-listp lst)))
  (cond ((endp lst) nil)
        (t (append (explode-atom (car lst) 10)
                   (packn1 (cdr lst))))))

(defun packn (lst)
  (declare (xargs :guard (good-atom-listp lst)))
  (let ((ans
; See comment in intern-in-package-of-symbol for an explanation of this trick.
         (intern (coerce (packn1 lst) 'string)
                 "ACL2")))
    ans))

(defun packn-pos (lst witness)
  (declare (xargs :guard (and (good-atom-listp lst)
                              (symbolp witness))))
  (intern-in-package-of-symbol (coerce (packn1 lst) 'string)
                               witness))

(defun pack2 (n1 n2)
  (packn (list n1 n2)))

(defun gen-formals-from-pretty-flags1 (pretty-flags i avoid)
  (cond ((endp pretty-flags) nil)
        ((eq (car pretty-flags) '*)
         (let ((xi (pack2 'x i)))
           (cond ((member-eq xi avoid)
                  (let ((new-var (genvar 'genvar ;;; ACL2 package
                                         "GENSYM"
                                         1
                                         avoid)))
                    (cons new-var
                          (gen-formals-from-pretty-flags1
                           (cdr pretty-flags)
                           (+ i 1)
                           (cons new-var avoid)))))
                 (t (cons xi
                          (gen-formals-from-pretty-flags1
                           (cdr pretty-flags)
                           (+ i 1)
                           avoid))))))
        (t (cons (car pretty-flags)
                 (gen-formals-from-pretty-flags1
                  (cdr pretty-flags)
                  (+ i 1)
                  avoid)))))

(defun gen-formals-from-pretty-flags (pretty-flags)

; Given a list of prettyified stobj flags, e.g., '(* * $S * STATE) we
; generate a proposed list of formals, e.g., '(X1 X2 $S X4 STATE).  We
; guarantee that the result is a list of symbols as long as
; pretty-flags.  Furthermore, a non-* in pretty-flags is preserved in
; the same slot in the output.  Furthermore, the symbol generated for
; each * in pretty-flags is unique and not among the symbols in
; pretty-flags.  Finally, STATE is not among the symbols we generate.

  (gen-formals-from-pretty-flags1 pretty-flags 1 pretty-flags))

(defun defstub-body (output)

; This strange little function is used to turn an output signature
; spec (in either the old or new style) into a term.  It never causes
; an error, even if output is ill-formed!  What it returns in that
; case is irrelevant.  If output is well-formed, i.e., is one of:

;       output               result
; *                           nil
; x                           x
; state                       state
; (mv * state *)              (mv nil state nil)
; (mv x state y)              (mv x state y)

; it replaces the *'s by nil and otherwise doesn't do anything.

  (cond ((atom output)
         (cond ((equal output '*) nil)
               (t output)))
        ((equal (car output) '*)
         (cons nil (defstub-body (cdr output))))
        (t (cons (car output) (defstub-body (cdr output))))))

(defun collect-non-x (x lst)

; This function preserves possible duplications of non-x elements in lst.
; We use this fact when we check the legality of signatures.

  (declare (xargs :guard (true-listp lst)))
  (cond ((endp lst) nil)
        ((equal (car lst) x)
         (collect-non-x x (cdr lst)))
        (t (cons (car lst) (collect-non-x x (cdr lst))))))

#+acl2-loop-only
(defmacro defproxy (name args-sig arrow body-sig)
  (cond
   ((not (and (symbol-listp args-sig)
              (symbolp arrow)
              (equal (symbol-name arrow) "=>")))
    (er hard 'defproxy
        "Defproxy must be of the form (proxy name args-sig => body-sig), ~
         where args-sig is a true-list of symbols.  See :DOC defproxy."))
   (t
    (let ((formals (gen-formals-from-pretty-flags args-sig))
          (body (defstub-body body-sig))
          (stobjs (collect-non-x '* args-sig)))
      `(defun ,name ,formals
         (declare (xargs :non-executable :program
                         :mode :program
                         ,@(and stobjs `(:stobjs ,stobjs)))
                  (ignorable ,@formals))

; The form of the body below is dictated by function throw-nonexec-error-p.
; Notice that we do not pass the formals to throw-nonexec-error as we do in
; defun-nx-fn, because if the formals contain a stobj then we would violate
; stobj restrictions, which are checked for non-executable :program mode
; functions.

         (prog2$ (throw-nonexec-error ',name nil)
                 ,body))))))

#-acl2-loop-only
(defmacro defproxy (name args-sig arrow body-sig)

; Note that a defproxy redefined using encapsulate can generate a warning in
; CLISP (see comment about CLISP in with-redefinition-suppressed), because
; indeed there are two definitions being made for the same name.  However, the
; definition generated for a function by encapsulate depends only on the
; function's signature, up to renaming of formals; see the #-acl2-loop-only
; definition of encapsulate.  So this redefinition is as benign as the
; redefinition that occurs in raw Lisp with a redundant defun.

  `(defstub ,name ,args-sig ,arrow ,body-sig))

; We now use encapsulate to implement defstub.  It is handy to do so here,
; rather than in other-events.lisp, since the raw Lisp definition of defproxy
; uses defstub.

(defun defstub-ignores (formals body)

; The test below is sufficient to ensure that the set-difference-equal
; used to compute the ignored vars will not cause an error.  We return
; a true list.  The formals and body will be checked thoroughly by the
; encapsulate, provided we generate it!  Provided they check out, the
; result returned is the list of ignored formals.

  (if (and (symbol-listp formals)
           (or (symbolp body)
               (and (consp body)
                    (symbol-listp (cdr body)))))
      (set-difference-equal
       formals
       (if (symbolp body)
           (list body)
         (cdr body)))
    nil))

; The following function is used to implement a slighly generalized
; form of macro args, namely one in which we can provide an arbitrary
; number of ordinary arguments terminated by an arbitrary number of
; keyword argument pairs.

(defun partition-rest-and-keyword-args1 (x)
  (cond ((endp x) (mv nil nil))
        ((keywordp (car x))
         (mv nil x))
        (t (mv-let (rest keypart)
                   (partition-rest-and-keyword-args1 (cdr x))
                   (mv (cons (car x) rest)
                       keypart)))))

(defun partition-rest-and-keyword-args2 (keypart keys alist)

; We return t if keypart is ill-formed as noted below.  Otherwise, we
; return ((:keyn . vn) ... (:key1 . v1)).

  (cond ((endp keypart) alist)
        ((and (keywordp (car keypart))
              (consp (cdr keypart))
              (not (assoc-eq (car keypart) alist))
              (member (car keypart) keys))
         (partition-rest-and-keyword-args2 (cddr keypart)
                                           keys
                                           (cons (cons (car keypart)
                                                       (cadr keypart))
                                                 alist)))
        (t t)))

(defun partition-rest-and-keyword-args (x keys)

; X is assumed to be a list of the form (a1 ... an :key1 v1 ... :keyk
; vk), where no ai is a keyword.  We return (mv erp rest alist), where
; erp is t iff the keyword section of x is ill-formed.  When erp is
; nil, rest is '(a1 ... an) and alist is '((:key1 . v1) ... (:keyk
; . vk)).

; The keyword section is ill-formed if it contains a non-keyword in an
; even numbered element, if it binds the same keyword more than once,
; or if it binds a keyword other than those listed in keys.

  (mv-let (rest keypart)
          (partition-rest-and-keyword-args1 x)
          (let ((alist (partition-rest-and-keyword-args2 keypart keys nil)))
            (cond
             ((eq alist t) (mv t nil nil))
             (t (mv nil rest alist))))))

(defmacro defstub (name &rest rst)
  (mv-let (erp args key-alist)
          (partition-rest-and-keyword-args rst '(:doc))
          (cond
           ((or erp
                (not (or (equal (length args) 2)
                         (and (equal (length args) 3)
                              (symbol-listp (car args))
                              (symbolp (cadr args))
                              (equal (symbol-name (cadr args)) "=>")))))
            `(er soft 'defstub
                 "Defstub must be of the form (defstub name formals ~
                  body) or (defstub name args-sig => body-sig), where ~
                  args-sig is a true-list of symbols.  Both ~
                  forms permit an optional, final :DOC doc-string ~
                  argument.  See :DOC defstub."))
           (t
            (let ((doc (cdr (assoc-eq :doc key-alist))))
              (cond
               ((equal (length args) 2)

; Old style
                (let* ((formals (car args))
                       (body (cadr args))
                       (ignores (defstub-ignores formals body)))
                  `(encapsulate
                    ((,name ,formals ,body))
                    (logic)
                    (local
                     (defun ,name ,formals
                       (declare (ignore ,@ignores))
                       ,body))
                    ,@(and (consp body)
                           (eq (car body) 'mv)
                           `((defthm ,(packn-pos (list "TRUE-LISTP-" name)
                                                 name)
                               (true-listp (,name ,@formals))
                               :rule-classes :type-prescription)))
                    ,@(if doc `((defdoc ,name ,doc)) nil))))
               (t (let* ((args-sig (car args))
                         (body-sig (caddr args))
                         (formals (gen-formals-from-pretty-flags args-sig))
                         (body (defstub-body body-sig))
                         (ignores (defstub-ignores formals body))
                         (stobjs (collect-non-x '* args-sig)))
                    `(encapsulate
                      (((,name ,@args-sig) => ,body-sig))
                      (logic)
                      (local
                       (defun ,name ,formals
                         (declare (ignore ,@ignores)
                                  (xargs :stobjs ,stobjs))
                         ,body))
                      ,@(and (consp body-sig)
                             (eq (car body-sig) 'mv)
                             `((defthm ,(packn-pos (list "TRUE-LISTP-" name)
                                                   name)
                                 (true-listp (,name ,@formals))
                                 :rule-classes :type-prescription)))
                      ,@(if doc `((defdoc ,name ,doc)) nil))))))))))

(defun lambda-keywordp (x)
  (and (symbolp x)
       (eql 1 (string<= "&" (symbol-name x)))))

(defun arglistp1 (lst)

; Every element of lst is a legal-variablep.

  (cond ((atom lst) (null lst))
        (t (and (legal-variablep (car lst))
                (arglistp1 (cdr lst))))))

(defun arglistp (lst)
  (and (arglistp1 lst)
       (no-duplicatesp lst)))

(defun find-first-bad-arg (args)

; This function is only called when args is known to be a non-arglistp
; that is a true list.  It returns the first bad argument and a string
; that completes the phrase "... violates the rules because it ...".

  (declare (xargs :guard (and (true-listp args)
                              (not (arglistp args)))))
  (cond
   ;;((null args) (mv nil nil)) -- can't happen, given the guard!
   ((not (symbolp (car args))) (mv (car args) "is not a symbol"))
   ((legal-constantp1 (car args))
    (mv (car args) "has the syntax of a constant"))
   ((lambda-keywordp (car args))
    (mv (car args) "is a lambda keyword"))
   ((keywordp (car args))
    (mv (car args) "is in the KEYWORD package"))
   ((member-eq (car args) *common-lisp-specials-and-constants*)
    (mv (car args) "belongs to the list *common-lisp-specials-and-constants* ~
                    of symbols from the main Lisp package"))
   ((member-eq (car args) (cdr args))
    (mv (car args) "occurs more than once in the list"))
   ((and (equal (symbol-package-name (car args)) *main-lisp-package-name*)
         (not (member-eq (car args) *common-lisp-symbols-from-main-lisp-package*)))
    (mv (car args) "belongs to the main Lisp package but not to the list ~
                    *common-lisp-symbols-from-main-lisp-package*"))
   (t (find-first-bad-arg (cdr args)))))

(defun process-defabbrev-declares (decls)
  (cond ((endp decls) ())

; Here we do a cheap check that the declare form is illegal.  It is tempting to
; use collect-declarations, but it take state.  Anyhow, there is no soundness
; issue; the user will just be a bit surprised when the error shows up later as
; the macro defined by the defabbrev is applied.

        ((not (and (consp (car decls))
                   (eq (caar decls) 'DECLARE)
                   (true-list-listp (cdar decls))
                   (subsetp-eq (strip-cars (cdar decls))
                               '(IGNORE IGNORABLE TYPE))))
         (er hard 'process-defabbrev-declares
             "In a DEFABBREV form, each expression after the argument list ~
              but before the body must be of the form (DECLARE decl1 .. ~
              declk), where each dcli is of the form (IGNORE ..), (IGNORABE ~
              ..), or (TYPE ..).  The form ~x0 is thus illegal."
             (car decls)))
        (t
         (cons (kwote (car decls))
               (process-defabbrev-declares (cdr decls))))))

(defmacro defabbrev (fn args &rest body)
  (cond ((null body)
         (er hard (cons 'defabbrev fn)
             "The body of this DEFABBREV form is missing."))
        ((not (true-listp args))
         (er hard (cons 'defabbrev fn)
             "The formal parameter list for a DEFABBREV must be a true list.  The ~
              argument list ~x0 is thus illegal."
             args))
        ((not (arglistp args))
         (mv-let (culprit explan)
                 (find-first-bad-arg args)
                 (er hard (cons 'defabbrev fn)
                     "The formal parameter list for a DEFABBREV must be a ~
                      list of distinct variables, but ~x0 does not meet these ~
                      conditions.  The element ~x1 ~@2."
                     args culprit explan)))
        (t
         (mv-let (doc-string-list body)
                 (if (and (stringp (car body))
                          (cdr body))
                     (mv (list (car body)) (cdr body))
                   (mv nil body))
                 (cond ((null body)
                        (er hard (cons 'defabbrev fn)
                            "This DEFABBREV form has a doc string but no ~
                             body."))
                       ((and (consp (car (last body)))
                             (eq (caar (last body)) 'declare))
                        (er hard (cons 'defabbrev fn)
                            "The body of this DEFABBREV form is a DECLARE ~
                             form, namely ~x0.  This is illegal and probably ~
                             is not what was intended."
                            (car (last body))))
                       (t
                        `(defmacro ,fn ,args
                           ,@doc-string-list
                           (list 'let (list ,@(defabbrev1 args))
                                 ,@(process-defabbrev-declares (butlast body 1))
                                 ',(car (last body))))))))))

;; RAG - I changed the primitive guard for the < function, and the
;; complex function.  Added the functions complexp, realp, and floor1.

;; RAG - I subsequently changed this to add the non-standard functions
;; standardp, standard-part and i-large-integer.  I had some
;; questions as to whether these functions should appear on this list
;; or not.  After considering carefully, I decided that was the right
;; course of action.  In addition to adding them to the list below, I
;; also add them to *non-standard-primitives* which is a special list
;; of non-standard primitives.  Functions in this list are considered
;; to be constrained.  Moreover, they are given the value t for the
;; property 'unsafe-induction so that recursion and induction are
;; turned off for terms built from these functions.

(defconst *primitive-formals-and-guards*

; Keep this in sync with ev-fncall-rec-logical and type-set-primitive, and with
; the documentation and "-completion" axioms of the primitives.  Also be sure
; to define a *1* function for each function in this list that is not a member
; of *oneify-primitives*.

; WARNING: for each primitive below, primordial-world puts a 'stobjs-in that is
; a list of nils of the same length as its formals, and a 'stobjs-out of
; '(nil).  Revisit that code if you add a primitive that involves stobjs!

; WARNING:  Just below you will find another list, *primitive-monadic-booleans*
; that lists the function names from this list that are monadic booleans.  The
; names must appear in the same order as here!

  '((acl2-numberp (x) 't)
    (bad-atom<= (x y) (if (bad-atom x) (bad-atom y) 'nil))
    (binary-* (x y) (if (acl2-numberp x) (acl2-numberp y) 'nil))
    (binary-+ (x y) (if (acl2-numberp x) (acl2-numberp y) 'nil))
    (unary-- (x) (acl2-numberp x))
    (unary-/ (x) (if (acl2-numberp x) (not (equal x '0)) 'nil))
    (< (x y)

; We avoid the temptation to use real/rationalp below, since it is a macro.

       (if #+:non-standard-analysis (realp x)
           #-:non-standard-analysis (rationalp x)
         #+:non-standard-analysis (realp y)
         #-:non-standard-analysis (rationalp y)
         'nil))
    (car (x) (if (consp x) 't (equal x 'nil)))
    (cdr (x) (if (consp x) 't (equal x 'nil)))
    (char-code (x) (characterp x))
    (characterp (x) 't)
    (code-char (x) (if (integerp x) (if (< x '0) 'nil (< x '256)) 'nil))
    (complex (x y)
             (if #+:non-standard-analysis (realp x)
                 #-:non-standard-analysis (rationalp x)
               #+:non-standard-analysis (realp y)
               #-:non-standard-analysis (rationalp y)
               'nil))
    (complex-rationalp (x) 't)
    #+:non-standard-analysis
    (complexp (x) 't)
    (coerce (x y)
            (if (equal y 'list)
                (stringp x)
                (if (equal y 'string)
                    (character-listp x)
                    'nil)))
    (cons (x y) 't)
    (consp (x) 't)
    (denominator (x) (rationalp x))
    (equal (x y) 't)
    #+:non-standard-analysis
    (floor1 (x) (realp x))
    (if (x y z) 't)
    (imagpart (x) (acl2-numberp x))
    (integerp (x) 't)
    (intern-in-package-of-symbol (str sym) (if (stringp str) (symbolp sym) 'nil))
    (numerator (x) (rationalp x))
    (pkg-imports (pkg) (stringp pkg))
    (pkg-witness (pkg) (if (stringp pkg) (not (equal pkg '"")) 'nil))
    (rationalp (x) 't)
    #+:non-standard-analysis
    (realp (x) 't)
    (realpart (x) (acl2-numberp x))
    (stringp (x) 't)
    (symbol-name (x) (symbolp x))
    (symbol-package-name (x) (symbolp x))
    (symbolp (x) 't)
    #+:non-standard-analysis
    (standardp (x) 't)
    #+:non-standard-analysis
    (standard-part (x) ; If (x) is changed here, change cons-term1-cases.
                   (acl2-numberp x))
    #+:non-standard-analysis
    (i-large-integer () 't)))

(defconst *primitive-monadic-booleans*

; This is the list of primitive monadic boolean function symbols.  Each
; function must be listed in *primitive-formals-and-guards* and they should
; appear in the same order.  (The reason order matters is simply to make it
; easier to check at the end of boot-strap that we have included all the
; monadic booleans.)

  '(acl2-numberp
    characterp
    complex-rationalp
    #+:non-standard-analysis
    complexp
    consp
    integerp
    rationalp
    #+:non-standard-analysis
    realp
    stringp
    symbolp
    #+:non-standard-analysis
    standardp))

(defun equal-x-constant (x const)

; x is an arbitrary term, const is a quoted constant, e.g., a list of
; the form (QUOTE guts).  We return a term equivalent to (equal x
; const).

  (let ((guts (cadr const)))
    (cond ((symbolp guts)
           (list 'eq x const))
          ((or (acl2-numberp guts)
               (characterp guts))
           (list 'eql x guts))
          ((stringp guts)
           (list 'equal x guts))
          (t (list 'equal x const)))))

(defun match-tests-and-bindings (x pat tests bindings)

; We return two results.  The first is a list of tests, in reverse
; order, that determine whether x matches the structure pat.  We
; describe the language of pat below.  The tests are accumulated onto
; tests, which should be nil initially.  The second result is an alist
; containing entries of the form (sym expr), suitable for use as the
; bindings in the let we generate if the tests are satisfied.  The
; bindings required by pat are accumulated onto bindings and thus are
; reverse order, although their order is actually irrelevant.

; For example, the pattern
;   ('equal ('car ('cons u v)) u)
; matches only first order instances of (EQUAL (CAR (CONS u v)) u).

; The pattern
;   ('equal (ev (simp x) a) (ev x a))
; matches only second order instances of (EQUAL (ev (simp x) a) (ev x a)),
; i.e., ev, simp, x, and a are all bound in the match.

; In general, the match requires that the cons structure of x be isomorphic
; to that of pat, down to the atoms in pat.  Symbols in the pat denote
; variables that match anything and get bound to the structure matched.
; Occurrences of a symbol after the first match only structures equal to
; the binding.  Non-symbolp atoms match themselves.

; There are some exceptions to the general scheme described above.  A
; cons structure starting with QUOTE matches only itself.  The symbols
; nil and t, and all symbols whose symbol-name starts with #\* match
; only structures equal to their values.  (These symbols cannot be
; legally bound in ACL2 anyway, so this exceptional treatment does not
; restrict us further.)  Any symbol starting with #\! matches only the
; value of the symbol whose name is obtained by dropping the #\!.
; This is a way of referring to already bound variables in the
; pattern.  Finally, the symbol & matches anything and causes no
; binding.

  (cond
   ((symbolp pat)
    (cond
     ((or (eq pat t)
          (eq pat nil))
      (mv (cons (list 'eq x pat) tests) bindings))
     ((and (> (length (symbol-name pat)) 0)
           (eql #\* (char (symbol-name pat) 0)))
      (mv (cons (list 'equal x pat) tests) bindings))
     ((and (> (length (symbol-name pat)) 0)
           (eql #\! (char (symbol-name pat) 0)))
      (mv (cons (list 'equal x
                      (intern (coerce (cdr (coerce (symbol-name pat)
                                                   'list))
                                      'string)
                              "ACL2"))
                tests)
          bindings))
     ((eq pat '&) (mv tests bindings))
     (t (let ((binding (assoc-eq pat bindings)))
          (cond ((null binding)
                 (mv tests (cons (list pat x) bindings)))
                (t (mv (cons (list 'equal x (cadr binding)) tests)
                       bindings)))))))
   ((atom pat)
    (mv (cons (equal-x-constant x (list 'quote pat)) tests)
        bindings))
   ((eq (car pat) 'quote)
    (mv (cons (equal-x-constant x pat) tests)
        bindings))
   (t (mv-let (tests1 bindings1)
        (match-tests-and-bindings (list 'car x) (car pat)
                                  (cons (list 'consp x) tests)
                                  bindings)
        (match-tests-and-bindings (list 'cdr x) (cdr pat)
                                  tests1 bindings1)))))

(defun match-clause (x pat forms)
  (mv-let (tests bindings)
    (match-tests-and-bindings x pat nil nil)
    (list (if (null tests)
              t
            (cons 'and (reverse tests)))
          (cons 'let (cons (reverse bindings) forms)))))

(defun match-clause-list (x clauses)
  (cond ((consp clauses)
         (if (eq (caar clauses) '&)
             (list (match-clause x (caar clauses) (cdar clauses)))
           (cons (match-clause x (caar clauses) (cdar clauses))
                 (match-clause-list x (cdr clauses)))))
        (t '((t nil)))))

(defmacro case-match (&rest args)
  (declare (xargs :guard (and (consp args)
                              (symbolp (car args))
                              (alistp (cdr args))
                              (null (cdr (member-equal (assoc-eq '& (cdr args))
                                                       (cdr args)))))))
  (cons 'cond (match-clause-list (car args) (cdr args))))

#+:non-standard-analysis
(defconst *non-standard-primitives*
  '(standardp
    standard-part
    i-large-integer))

(defun cons-term1-cases (alist)

; Initially, alist is *primitive-formals-and-guards*.

  (cond ((endp alist) nil)
        ((member-eq (caar alist)
                    '(if ; IF is handled directly in cons-term1-body.
                         bad-atom<= pkg-imports pkg-witness))
         (cons-term1-cases (cdr alist)))
        (t (cons (let* ((trip (car alist))
                        (fn (car trip))
                        (formals (cadr trip))
                        (guard (caddr trip)))
                   (list
                    fn
                    (cond #+:non-standard-analysis
                          ((eq fn 'i-large-integer)
                           nil) ; fall through in cons-term1-body
                          #+:non-standard-analysis
                          ((eq fn 'standardp)
                           '(kwote t))
                          #+:non-standard-analysis
                          ((eq fn 'standard-part)
                           (assert$
                            (eq (car formals) 'x)
                            `(and ,guard ; a term in variable x
                                  (kwote ,@formals))))
                          ((equal guard *t*)
                           `(kwote (,fn ,@formals)))
                          ((or (equal formals '(x))
                               (equal formals '(x y)))
                           `(and ,guard
                                 (kwote (,fn ,@formals))))
                          (t (case-match formals
                               ((f1)
                                `(let ((,f1 x))
                                   (and ,guard
                                        (kwote (,fn ,@formals)))))
                               ((f1 f2)
                                `(let ((,f1 x)
                                       (,f2 y))
                                   (and ,guard
                                        (kwote (,fn ,@formals)))))
                               (& (er hard! 'cons-term1-cases
                                      "Unexpected formals, ~x0"
                                      formals)))))))
                 (cons-term1-cases (cdr alist))))))

(defconst *cons-term1-alist*
  (cons-term1-cases *primitive-formals-and-guards*))

(defmacro cons-term1-body ()
  `(let ((x (unquote (car args)))
         (y (unquote (cadr args))))
     (or (case fn
           ,@*cons-term1-alist*
           (if (kwote (if x y (unquote (caddr args)))))
           (not (kwote (not x))))
         (cons fn args))))

(defun quote-listp (l)
  (declare (xargs :guard (true-listp l)))
  (cond ((null l) t)
        (t (and (quotep (car l))
                (quote-listp (cdr l))))))

(defun cons-term1 (fn args)
  (declare (xargs :guard (and (pseudo-term-listp args)
                              (quote-listp args))))
  (cons-term1-body))

(defun cons-term (fn args)
  (declare (xargs :guard (pseudo-term-listp args)))
  (cond ((quote-listp args)
         (cons-term1 fn args))
        (t (cons fn args))))

(defmacro cons-term* (fn &rest args)
  `(cons-term ,fn (list ,@args)))

(defmacro mcons-term (fn args)

; The "m" in "mcons-term" is for "maybe fast".  Some calls of this macro can
; probably be replaced with fcons-term.

  `(cons-term ,fn ,args))

(defmacro mcons-term* (fn &rest args)

; The "m" in "mcons-term*" is for "maybe fast".  Some of calls of this macro
; can probably be replaced with fcons-term*.

  `(cons-term* ,fn ,@args))

(defmacro fcons-term (fn args)

; ; Start experimental code mod, to check that calls of fcons-term are legitimate
; ; shortcuts in place of the corresponding known-correct calls of cons-term.
;   #-acl2-loop-only
;   `(let* ((fn-used-only-in-fcons-term ,fn)
;           (args-used-only-in-fcons-term ,args)
;           (result (cons fn-used-only-in-fcons-term
;                         args-used-only-in-fcons-term)))
;      (assert$ (equal result (cons-term fn-used-only-in-fcons-term
;                                        args-used-only-in-fcons-term))
;               result))
;   #+acl2-loop-only
; ; End experimental code mod.

  (list 'cons fn args))

(defun fargn1 (x n)
  (declare (xargs :guard (and (integerp n)
                              (> n 0))))
  (cond ((eql n 1) (list 'cdr x))
        (t (list 'cdr (fargn1 x (- n 1))))))

(defmacro fargn (x n)
  (list 'car (fargn1 x n)))

(defun cdr-nest (n v)
  (cond ((equal n 0) v)
        (t (fargn1 v n))))

(defun all-but-last (l)
  (declare (xargs :guard (true-listp l) ; and let's verify termination/guards:
                  :mode :logic))
  (cond ((endp l) nil)
        ((endp (cdr l)) nil)
        (t (cons (car l) (all-but-last (cdr l))))))

; Essay on Evisceration

; We have designed the pretty printer so that it can print an
; "eviscerated" object, that is, an object that has had certain
; substructures removed.  We discuss the prettyprinter in the Essay on
; the ACL2 Prettyprinter.  The pretty printer has a flag, eviscp,
; which indicates whether the object has been eviscerated or not.  If
; not, then the full object is printed as it stands.  If so, then
; certain substructures of it are given special interpretation by the
; printer.  In particular, when the printer encounters a cons of the
; form (:evisceration-mark . x) then x is a string and the cons is
; printed by printing the characters in x (without the double
; gritches).

;     object                            pretty printed output
; (:evisceration-mark . "#")                     #
; (:evisceration-mark . "...")                   ...
; (:evisceration-mark . "<state>")               <state>
; (:evisceration-mark . ":EVISCERATION-MARK")    :EVISCERATION-MARK

; So suppose you have some object and you want to print it, implementing
; the CLTL conventions for *print-level* and *print-length*.  Then you
; must first scan it, inserting :evisceration-mark forms where
; appropriate.  But what if it contains some occurrences of
; :evisceration-mark?  Then you must use evisceration mechanism to print
; them correctly!  Once you have properly eviscerated the object, you can
; call the prettyprinter on it, telling it that the object has been
; eviscerated.  If, on the other hand, you don't want to eviscerate it,
; then you needn't sweep it to protect the native :evisceration-marks:
; just call the prettyprinter with the eviscp flag off.

(defconst *evisceration-mark* :evisceration-mark)

; Note: It is important that the evisceration-mark be a keyword.
; One reason is that (:evisceration-mark . ":EVISCERATION-MARK")
; couldn't be used to print a non-keyword because the package might
; need to be printed.  Another is that we exploit the fact that no
; event name nor any formal is *evisceration-mark*.  See
; print-ldd-full-or-sketch.  Furthermore, if the particular keyword
; chosen is changed, alter *anti-evisceration-mark* below!

(defconst *evisceration-hash-mark* (cons *evisceration-mark* "#"))
(defconst *evisceration-ellipsis-mark* (cons *evisceration-mark* "..."))
(defconst *evisceration-world-mark*
  (cons *evisceration-mark* "<world>"))
(defconst *evisceration-state-mark*
  (cons *evisceration-mark* "<state>"))
(defconst *evisceration-error-triple-marks*
  (list nil nil *evisceration-state-mark*))
(defconst *evisceration-hiding-mark*
  (cons *evisceration-mark* "<hidden>"))

(defconst *anti-evisceration-mark*
  (cons *evisceration-mark* ":EVISCERATION-MARK"))

(defmacro evisceratedp (eviscp x)
; Warning:  The value of x should be a consp.
  `(and ,eviscp (eq (car ,x) *evisceration-mark*)))

; Essay on Iprinting

; Through Version_3.4, when ACL2 eviscerated a form using a print-level or
; print-length from an evisc-tuple, the resulting # and ... made it impossible
; to read the form back in.  We have implemented "iprinting" (think
; "interactive printing") to deal with this problem.  Our implementation uses
; an "iprint array", or "iprint-ar" for short, as described below.  Now, when
; iprinting is enabled, then instead of # or ... we will see #@i# for i = 1, 2,
; etc.  See :doc set-iprint for more information at the user level.  In brief,
; the idea is to maintain a state global 'iprint-ar whose value is an ACL2
; array that associates each such i with its hidden value.  (This use of #@i#
; allows us also to think of "iprinting" as standing for "index printing" or "i
; printing".)

; We implement this idea by modifying the recursive subroutines of eviscerate
; to accumulate each association of a positive i with its hidden value. When
; fmt (or fms, etc.) is called, eviscerate-top or eviscerate-stobjs-top will be
; called in order to update the existing 'iprint-ar with those new
; associations.

; We use index 0 to store the most recent i for which #@i# has been printed,
; assuming iprinting is enabled, or else (list i) if iprinting is disabled.  We
; call such i the last-index, and it is initially 0.  Note that state global
; 'iprint-ar is thus always bound to an installed ACL2 array.

; We have to face a fundamental question: Do we use acons or aset1 as we
; encounter a new form to assign to some #@i# during those recursive
; subroutines?  The latter is dangerous in case we interrupt before installing
; the result in the state global.  So it's tempting to use acons -- but it
; could be inefficient to compress the iprint-ar on each top-level call.  So
; instead we use acons to build up a new alist from scratch.  Then at the
; top level, we apply aset1 for each entry if we can do so without needing to
; ``rollover'', i.e., set the last-index back to 0; otherwise we call compress1
; rather than making a series of aset1 calls.  With luck this final step will
; be fast and unlikely to be interrupted from the time the first aset1 or
; compress1 is applied until the state global 'iprint-ar is updated.

; Let's also comment on why we have a soft and a hard bound (as described in
; :doc set-iprint).  In general we allow indices to increase between successive
; top-level invocations, so that the user can read back in any forms that were
; printed. But the soft bound forces a rollover at the top level of LD when the
; last-index exceeds that bound, so that we don't hold on to a potentially
; unbounded amount of space for the objects in the iprint-ar. The hard bound
; (which generally exceeds the soft bound) steps in if the last-index exceeds
; it after pretty-printing a single form.  Thus, if there are large objects and
; very long runs between successive top-level forms, space can be
; reclaimed. The hard bound is therefore probably less likely to be of use.

; We maintain the invariant that the dimension of state global 'iprint-ar
; exceeds the hard bound.  Thus, when we update the 'iprint-ar in the normal
; case that the hard bound is not exceeded, then the dimension will not be
; exceeded either; that is, every update will be with an index that is in
; bounds.  In order to maintain this invariant, the hard bound is untouchable,
; and its setter function compresses the global iprint-ar with a new dimension
; that exceeds the specified hard bound.  Therefore the hard bound must be a
; number, not nil.  Notice that with this invariant, we can avoid compressing
; twice when we roll over upon exceeding the hard or soft bound: we first reset
; the last-index to 0 and then do the compression, rather than compressing once
; for the increased dimension and once for the rollover.

; We also maintain the invariant that the maximum-length of the 'iprint-ar is
; always at least four times its dimension.  See the comment about this in
; rollover-iprint-ar.

; It is tempting to cause an error when the user submits a form containing some
; #@j# and #@k# such that j <= last-index < k.  In such a case, k is from
; before the rollover and j is from after the rollover, so these couldn't have
; been stored during a prettyprint of the same form.  But we avoid considering
; this restriction because the user might want to read a list of forms that
; include some prettyprinted before the last rollover and others printed after
; the last rollover.  At any time, the reader is happy with #@j# for any index
; j <= last-index and also any j below the maximum index before the last
; rollover (initially 0).

; We need to be sure that the global iprint-ar is installed as an ACL2 array, in
; order to avoid slow-array-warnings.  See the comment in
; push-wormhole-undo-formi for how we deal with this issue in the presence of
; wormholes.

; End of Essay on Iprinting

(defconst *sharp-atsign-ar* ; see get-sharp-atsign
  (let ((dim (1+ *iprint-hard-bound-default*)))
    (compress1
     'sharp-atsign-ar
     (cons `(:HEADER :DIMENSIONS     (,dim)
                     :MAXIMUM-LENGTH ,(1+ dim) ; no duplicates expected
                     :NAME           sharp-atsign-ar)
           (sharp-atsign-alist *iprint-hard-bound-default* nil)))))

(defun get-sharp-atsign (i)

; If i is below the hard bound, then we get the string #@i# from a fixed array,
; so that we don't have to keep consing up that string.

  (declare (xargs :guard (posp i)))
  (cond ((<= i *iprint-hard-bound-default*)
         (aref1 'sharp-atsign-ar *sharp-atsign-ar* i))
        (t (make-sharp-atsign i))))

(defun update-iprint-alist (iprint-alist val)

; We are doing iprinting.  Iprint-alist is either a positive integer,
; representing the last-index but no accumulated iprint-alist, or else is a
; non-empty alist of entries (i . val_i).  See the Essay on Iprinting.

  (cond ((consp iprint-alist)
         (let ((i (1+ (caar iprint-alist))))
           (acons i val iprint-alist)))
        (t ; iprint-alist is a natp
         (acons (1+ iprint-alist) val nil))))

; We now define the most elementary eviscerator, the one that implements
; *print-level* and *print-length*.  In this same pass we also arrange to
; hide any object in alist, where alist pairs objects with their
; evisceration strings -- or if not a string, with the appropriate
; evisceration pair.

(mutual-recursion

(defun eviscerate1 (x v max-v max-n alist evisc-table hiding-cars iprint-alist)

; Iprint-alist is either a symbol, indicating that we are not doing iprinting; a
; positive integer, representing the last-index but no accumulated iprint-alist;
; or an accumulated alist of entries (i . val_i).  See the Essay on Iprinting.
; Note that if iprint-alist is a symbol, then it is nil if no evisceration has
; been done based on print-length or print-level, else t.

  (let ((temp (or (hons-assoc-equal x alist)
                  (hons-assoc-equal x evisc-table))))
    (cond ((cdr temp)
           (mv (cond ((stringp (cdr temp))
                      (cons *evisceration-mark* (cdr temp)))
                     (t (cdr temp)))
               iprint-alist))
          ((atom x)
           (mv (cond ((eq x *evisceration-mark*) *anti-evisceration-mark*)
                     (t x))
               iprint-alist))
          ((= v max-v)
           (cond ((symbolp iprint-alist)
                  (mv *evisceration-hash-mark* t))
                 (t
                  (let ((iprint-alist (update-iprint-alist iprint-alist x)))
                    (mv (cons *evisceration-mark*
                              (get-sharp-atsign (caar iprint-alist)))
                        iprint-alist)))))
          ((member-eq (car x) hiding-cars)
           (mv *evisceration-hiding-mark* iprint-alist))
          (t (eviscerate1-lst x (1+ v) 0 max-v max-n alist evisc-table
                              hiding-cars iprint-alist)))))

(defun eviscerate1-lst (lst v n max-v max-n alist evisc-table hiding-cars
                            iprint-alist)
  (let ((temp (or (hons-assoc-equal lst alist)
                  (hons-assoc-equal lst evisc-table))))
    (cond
     ((cdr temp)
      (mv (cond ((stringp (cdr temp))
                 (cons *evisceration-mark* (cdr temp)))
                (t (cdr temp)))
          iprint-alist))
     ((atom lst)
      (mv (cond ((eq lst *evisceration-mark*) *anti-evisceration-mark*)
                (t lst))
          iprint-alist))
     ((= n max-n)
      (cond ((symbolp iprint-alist)
             (mv (list *evisceration-ellipsis-mark*) t))
            (t
             (let ((iprint-alist (update-iprint-alist iprint-alist lst)))
               (mv (cons *evisceration-mark*
                         (get-sharp-atsign (caar iprint-alist)))
                   iprint-alist)))))
     (t (mv-let (first iprint-alist)
                (eviscerate1 (car lst) v max-v max-n alist evisc-table
                             hiding-cars iprint-alist)
                (mv-let (rest iprint-alist)
                        (eviscerate1-lst (cdr lst) v (1+ n)
                                         max-v max-n alist evisc-table
                                         hiding-cars iprint-alist)
                        (mv (cons first rest) iprint-alist)))))))
)

(mutual-recursion

(defun eviscerate1p (x alist evisc-table hiding-cars)

; This function returns t iff (eviscerate1 x 0 -1 -1 alist evisc-table hidep)
; returns something other than x.  That is, iff the evisceration of x either
; uses alist, evisc-table, hiding or the *anti-evisceration-mark* (assuming
; that print-level and print-length never max out).

  (let ((temp (or (hons-assoc-equal x alist)
                  (hons-assoc-equal x evisc-table))))
    (cond ((cdr temp) t)
          ((atom x)
           (cond ((eq x *evisceration-mark*) t)
                 (t nil)))
          ((member-eq (car x) hiding-cars) t)
          (t (eviscerate1p-lst x alist evisc-table hiding-cars)))))

(defun eviscerate1p-lst (lst alist evisc-table hiding-cars)
  (let ((temp (or (hons-assoc-equal lst alist)
                  (hons-assoc-equal lst evisc-table))))
    (cond ((cdr temp) t)
          ((atom lst)
           (cond ((eq lst *evisceration-mark*) t)
                 (t nil)))
          (t (or (eviscerate1p (car lst) alist evisc-table hiding-cars)
                 (eviscerate1p-lst (cdr lst) alist evisc-table
                                   hiding-cars))))))
)

(defun eviscerate (x print-level print-length alist evisc-table hiding-cars
                     iprint-alist)

; See also eviscerate-top, which takes iprint-ar from the state and installs a
; new iprint-ar in the state, and update-iprint-alist, which describes the role
; of a non-symbol iprint-alist as per the Essay on Iprinting.

; Print-level and print-length should either be non-negative integers or nil.
; Alist and evisc-table are alists pairing arbitrary objects to strings or
; other objects.  Hiding-cars is a list of symbols.  Any x that starts with one
; of these symbols is printed as <hidden>.  If alist or evisc-table pairs an
; object with a string, the string is printed in place of the object.  If alist
; or evisc-table pairs an object with anything else, x, then x is substituted
; for the the object and is treated as eviscerated.  In general, alist will
; come from an evisceration tuple and evisc-table will be the value of the
; 'evisc-table table in the current ACL2 world.  We give priority to the former
; because the user may want to override the evisc-table, for example using ~P
; in a call of fmt.

; This function copies the structure x and replaces certain deep substructures
; with evisceration marks.  The determination of which substructures to so
; abbreviate is based on the same algorithm used to define *print-level* and
; *print-length* in CLTL, with the additional identification of all occurrences
; of any object in alist or evisc-table.

; For example, if x is '(if (member x y) (+ (car x) 3) '(foo . b)) and
; print-level is 2 and print-length is 3 then the output is:

; (IF (MEMBER X Y)
;     (+ (*evisceration-mark* . "#") 3)
;     (*evisceration-mark* . "..."))

; See pg 373 of CLTL.

; Of course we are supposed to print this as:

; (IF (MEMBER X Y) (+ # 3) ...)

; We consider a couple of special cases to reduce unnecessary consing
; of eviscerated values.

  (cond ((and (null print-level)
              (null print-length))

; Warning: Observe that even if alist is nil, x might contain the
; *evisceration-mark* or hiding expressions and hence have a
; non-trivial evisceration

         (cond ((eviscerate1p x alist evisc-table hiding-cars)
                (eviscerate1 x 0 -1 -1 alist evisc-table hiding-cars
                             iprint-alist))
               (t (mv x iprint-alist))))
        (t (eviscerate1 x 0
                        (or print-level -1)
                        (or print-length -1)
                        alist
                        evisc-table
                        hiding-cars
                        iprint-alist))))

(defun eviscerate-simple (x print-level print-length alist evisc-table
                            hiding-cars)

; This wrapper for eviscerate avoids the need to pass back multiple values when
; the iprint-alist is nil and we don't care if evisceration has occurred.

  (mv-let (result null-iprint-alist)
          (eviscerate x print-level print-length alist evisc-table hiding-cars
                      nil)
          (assert$ (symbolp null-iprint-alist)
                   result)))

(defun aset1-lst (name alist ar)
  (declare (xargs :guard (eqlable-alistp alist))) ; really nat-alistp
  (cond ((endp alist)
         ar)
        (t (aset1-lst name
                      (cdr alist)
                      (aset1 name ar (caar alist) (cdar alist))))))

; Next we define accessors for iprint arrays.

(defun iprint-hard-bound (state)
  (f-get-global 'iprint-hard-bound state))

(defun iprint-soft-bound (state)
  (f-get-global 'iprint-soft-bound state))

(defun iprint-last-index* (iprint-ar)
  (declare (xargs :guard (array1p 'iprint-ar iprint-ar)))
  (let ((x (aref1 'iprint-ar iprint-ar 0)))
    (if (consp x) ; iprinting is disabled
        (car x)
      x)))

(defun iprint-last-index (state)
  (iprint-last-index* (f-get-global 'iprint-ar state)))

(defun iprint-ar-illegal-index (index state)
  (declare (xargs :guard (and (natp index) (state-p state))))
  (or (zp index)
      (let* ((iprint-ar (f-get-global 'iprint-ar state))
             (bound (default 'iprint-ar iprint-ar)))
        (if (null bound)
            (> index (iprint-last-index* iprint-ar))
          (> index bound)))))

(defun iprint-enabledp (state)
  (natp (aref1 'iprint-ar (f-get-global 'iprint-ar state) 0)))

(defun iprint-ar-aref1 (index state)

; We do not try to determine if the index is appropriate, other than to avoid a
; guard violation on the aref1 call.  See the Essay on Iprinting.

  (declare (xargs :guard (and (posp index) (state-p state))))
  (let ((iprint-ar (f-get-global 'iprint-ar state)))

;; PAPER:
; We use a raw Lisp error since otherwise we get an error such as "Can't throw
; to tag RAW-EV-FNCALL".

    #-acl2-loop-only
    (cond ((>= index (car (dimensions 'iprint-ar iprint-ar)))

; The following error probably never occurs, since we have already done a
; bounds check with iprint-ar-illegal-index.

           (error
            "Out of range index for iprinting: ~s.~%See :DOC set-iprint."
            index)))
    (aref1 'iprint-ar iprint-ar index)))

(defun collect-posp-indices-to-header (ar acc)

; Accumulates the reverse of ar onto acc, skipping entries with index 0 and
; stopping just before the :header.

  (cond ((endp ar)
         (er hard 'collect-posp-indices-to-header
             "Implementation error: Failed to find :HEADER as expected!"))
        ((eq (caar ar) :HEADER)
         acc)
        (t
         (collect-posp-indices-to-header (cdr ar)
                                         (if (eql (caar ar) 0)
                                             acc
                                           (cons (car ar) acc))))))

(defun rollover-iprint-ar (iprint-alist last-index state)

; We assume that iprinting is enabled.  Install a new iprint-ar, whose last
; index before rollover is intended to be last-index and whose alist is
; intended to extend state global 'iprint-ar, as the new (and compressed) value
; of state global 'iprint-ar.

  (let* ((old-iprint-ar (f-get-global 'iprint-ar state))
         (new-dim

; Clearly last-index exceeds the iprint-hard-bound, as required by one of our
; invariants (see the Essay on Iprinting), if we are rolling over because
; last-index exceeds that hard bound.  But we can also call rollover-iprint-ar
; when exceeding the soft bound, which may be smaller than the hard bound (it
; probably is smaller, typically).  The taking of this max is cheap so we
; always do it, so that rollover-iprint-ar will always preserve the above
; invariant.

; To illustrate the above point, evaluate the following forms in a fresh ACL2
; session and see the error if we bind new-dim to (1+ last-index).

; (set-ld-evisc-tuple (evisc-tuple 2 3 nil nil) state)
; (set-iprint t :soft-bound 2 :hard-bound 7)
; '((a b c d e) (a b c d e) (a b c d e))
; '((a b c d e) (a b c d e) (a b c d e) (a b c d e) (a b c d e))

          (1+ (max (iprint-hard-bound state) last-index)))
         (new-max-len

; A multiplier of 4 allows us to maintain the invariant that the maximum-length
; is always at least four times the dimension.  This guarantees that the
; 'iprint-ar alist never reaches the maximum-length because it never reaches
; 4*d, where d is the dimension, as this alist has at most:
; - up to d-2 values for index >= 1 since the latest rollover;
; - up to d-2 values for index >= 1 before the latest rollover;
; - at most two headers (the 2nd is just before a new compression at rollover)
; - no two successive bindings of index 0
; So without considering index 0, the maximum is (d-2 + d-2 + 2) = 2d-1.  Now
; for the bindings of index 0, double that and add one to get 4d-1.

; Thus, since the dimension never decreases (except when we reinitialize), we
; are assured that our use of aset1-lst in update-iprint-ar will never cause a
; recompression.  See also corresponding comments in disable-iprint-ar and
; enable-iprint-ar.

          (* 4 new-dim))
         (new-header
          (prog2$
           (or (<= new-max-len *maximum-positive-32-bit-integer*)
               (er hard 'rollover-iprint-ar
                   "Attempted to expand iprint-ar to a maximum-length of ~x0, ~
                    exceeding *maximum-positive-32-bit-integer*, which is ~x1."
                   new-max-len
                   *maximum-positive-32-bit-integer*))
           `(:HEADER :DIMENSIONS     (,new-dim)
                     :MAXIMUM-LENGTH ,new-max-len
                     :DEFAULT        ,last-index
                     :NAME           iprint-ar
                     :ORDER          :none)))
         (new-iprint-ar
          (compress1 'iprint-ar
                     (cons new-header
                           (acons 0 0
                                  (collect-posp-indices-to-header
                                   old-iprint-ar

; If we change the :order to < from :none, then we need to reverse iprint-alist
; just below.  But first read the comment in disable-iprint-ar to see why we
; changing the :order from :none requires some thought.

                                   iprint-alist))))))
    (f-put-global 'iprint-ar new-iprint-ar state)))

(defun update-iprint-ar (iprint-alist state)

; We assume that iprinting is enabled.  Iprint-alist is known to be a consp.
; We update state global 'iprint-ar by updating iprint-ar with the pairs in
; iprint-alist.

  (let ((last-index (caar iprint-alist)))
    (cond ((> last-index (iprint-hard-bound state))
           (rollover-iprint-ar iprint-alist last-index state))
          (t
           (f-put-global 'iprint-ar

; We know last-index <= (iprint-hard-bound state), and it is an invariant that
; this hard bound is less than the dimension of (@ iprint-ar).  See the
; discussion of this invariant in the Essay on Iprinting.  So last-index is
; less than that dimension, hence we can update with aset1 without encountering
; out-of-bounds indices.

                         (aset1-lst 'iprint-ar
                                    (acons 0 last-index iprint-alist)
                                    (f-get-global 'iprint-ar state))
                         state)))))

(defun eviscerate-top (x print-level print-length alist evisc-table hiding-cars
                         state)

; We take iprint-ar from the state and then install a new iprint-ar in the state,
; in addition to returning the evisceration of x.  See eviscerate and the Essay
; on Iprinting for more details.

  (mv-let (result iprint-alist)
          (eviscerate x print-level print-length alist evisc-table hiding-cars
                      (and (iprint-enabledp state)
                           (iprint-last-index state)))
          (let ((state (cond ((eq iprint-alist t)
                              (f-put-global 'evisc-hitp-without-iprint t state))
                             ((atom iprint-alist) state)
                             (t (update-iprint-ar iprint-alist state)))))
            (mv result state))))

(defun world-evisceration-alist (state alist)
  (let ((wrld (w state)))
    (cond ((null wrld) ; loading during the build
           alist)
          (t (cons (cons wrld *evisceration-world-mark*)
                   alist)))))

(defun stobj-print-name (name)
  (coerce
   (cons #\<
         (append (string-downcase1 (coerce (symbol-name name) 'list))
                 '(#\>)))
   'string))

(defun evisceration-stobj-mark (name inputp)

; NAME is a stobj name.  We return an evisceration mark that prints as
; ``<name>''.  We make a special case out of STATE.

  (cond
   (inputp name)
   ((eq name 'STATE)
    *evisceration-state-mark*)
   (t
    (cons *evisceration-mark* (stobj-print-name name)))))

(defun evisceration-stobj-marks1 (stobjs-flags inputp)

; See the comment in eviscerate-stobjs, below.

  (cond ((null stobjs-flags) nil)
        ((car stobjs-flags)
         (cons (evisceration-stobj-mark (car stobjs-flags) inputp)
               (evisceration-stobj-marks1 (cdr stobjs-flags) inputp)))
        (t
         (cons nil
               (evisceration-stobj-marks1 (cdr stobjs-flags) inputp)))))

(defconst *error-triple-sig*
  '(nil nil state))

(defconst *cmp-sig*
  '(nil nil))

(defun evisceration-stobj-marks (stobjs-flags inputp)
  (cond ((equal stobjs-flags *error-triple-sig*)
         (if inputp
             *error-triple-sig*
           *evisceration-error-triple-marks*))
        ((equal stobjs-flags '(nil)) '(nil))
        (t (evisceration-stobj-marks1 stobjs-flags inputp))))

(defun eviscerate-stobjs1 (estobjs-out lst print-level print-length
                                       alist evisc-table hiding-cars
                                       iprint-alist)
  (cond
   ((null estobjs-out) (mv nil iprint-alist))
   ((car estobjs-out)
    (mv-let (rest iprint-alist)
            (eviscerate-stobjs1 (cdr estobjs-out) (cdr lst)
                                print-level print-length
                                alist evisc-table hiding-cars iprint-alist)
            (mv (cons (car estobjs-out) rest)
                iprint-alist)))
   (t (mv-let (first iprint-alist)
              (eviscerate (car lst) print-level print-length
                          alist evisc-table hiding-cars iprint-alist)
              (mv-let (rest iprint-alist)
                      (eviscerate-stobjs1 (cdr estobjs-out) (cdr lst)
                                          print-level print-length alist
                                          evisc-table hiding-cars iprint-alist)
                      (mv (cons first rest) iprint-alist))))))

(defun eviscerate-stobjs (estobjs-out lst print-level print-length
                                      alist evisc-table hiding-cars
                                      iprint-alist)

; See also eviscerate-stobjs-top, which takes iprint-ar from the state and
; installs a new iprint-ar in the state.

; Warning: Right now, we abbreviate all stobjs with the <name> convention.  I
; have toyed with the idea of allowing the user to specify how a stobj is to be
; abbreviated on output.  This is awkward.  See the Essay on Abbreviating Live
; Stobjs below.

; We wish to eviscerate lst with the given print-level, etc., but respecting
; stobjs that we may find in lst.  Estobjs-out describes the shape of lst as a
; multiple value vector: if estobjs-out is of length 1, then lst is the single
; result; otherwise, lst is a list of as many elements as estobjs-out is long.
; The non-nil elements of stobjs name the stobjs in lst -- EXCEPT that unlike
; an ordinary ``stobjs-out'', the elements of estobjs-out are evisceration
; marks we are to ``print!''  For example corresponding to the stobjs-out
; setting of '(NIL $MY-STOBJ NIL STATE) is the estobjs-out

; '(NIL
;   (:EVISCERATION-MARK . "<$my-stobj>")
;   NIL
;   (:EVISCERATION-MARK . "<state>"))

; Here, we assume *evisceration-mark* is :EVISCERATION-MARK.

  (cond
   ((null estobjs-out)

; Lst is either a single non-stobj output or a list of n non-stobj outputs.  We
; eviscerate it without regard for stobjs.

    (eviscerate lst print-level print-length alist evisc-table hiding-cars
                iprint-alist))
   ((null (cdr estobjs-out))

; Lst is a single output, which is either a stobj or not depending on whether
; (car stobjs-out) is non-nil.

    (cond
     ((car estobjs-out)
      (mv (car estobjs-out) iprint-alist))
     (t (eviscerate lst print-level print-length alist evisc-table
                    hiding-cars iprint-alist))))
   (t (eviscerate-stobjs1 estobjs-out lst print-level print-length
                          alist evisc-table hiding-cars iprint-alist))))

(defun eviscerate-stobjs-top (estobjs-out lst print-level print-length
                                          alist evisc-table hiding-cars
                                          state)

; See eviscerate-stobjs.

  (mv-let (result iprint-alist)
          (eviscerate-stobjs estobjs-out lst print-level print-length alist
                             evisc-table hiding-cars
                             (and (iprint-enabledp state)
                                  (iprint-last-index state)))
          (let ((state (cond ((eq iprint-alist t)
                              (f-put-global 'evisc-hitp-without-iprint t state))
                             ((atom iprint-alist) state)
                             (t (update-iprint-ar iprint-alist state)))))
            (mv result state))))

; Essay on Abbreviating Live Stobjs

; Right now the live state is abbreviated as <state> when it is printed, and
; the user's live stobj $s is abbreviated as <$s>.  It would be cool if the
; user could specify how he or she wants a stobj displayed, e.g., by selecting
; key components for printing or by providing a function which maps the stobj
; to some non-stobj ``stand-in'' or eviscerated object for printing.

; I have given this matter several hours' thought and abandoned it for the
; moment.  I am not convinced it is worth the trouble.  It IS a lot of trouble.

; We eviscerate stobjs in the read-eval-print loop.  (Through Version_4.3, we
; also eviscerated stobjs in a very low-level place: ev-fncall-msg (and its
; more pervasive friend, ev-fncall-guard-er), used to print stobjs involved in
; calls of functions on args that violate a guard.)

; Every stobj must have some ``stand-in transformer'' function, fn.  We will
; typically be holding a stobj name, e.g., $S, and a live value, val, e.g.,
; (#(777) #(1 2 3 ...)), and wish to obtain some ACL2 object to print in place
; of the value.  This value is obtained by applying fn to val.  The two main
; issues I see are

; (a) where do we find fn?  The candidate places are state, world, and val
; itself.  But we do not have state available in the low-level code.

; (b) how do we apply fn to val?  The obvious thing is to call trans-eval or do
; an ev-fncall.  Again, we need state.  Furthermore, depending on how we do it,
; we have to fight a syntactic battle of ``casting'' an arbitrary object, val,
; to a stobj of type name, to apply a function which has a STOBJS-IN of (name).
; A more important problem is the one of order-of-definition.  Which is defined
; first: how to eviscerate a stobj or how to evaluate a form?  Stobj
; evisceration calls evaluation to apply fn, but evaluation calls stobj
; evisceration to report guard errors.

; Is user-specified stobj abbreviation really worth the trouble?

; One idea that presents itself is that val ``knows how to abbreviate itself.''
; I think this is akin to the idea of having a :program mode function, say
; stobj-standin, which syntactically takes a non-stobj and returns a non-stobj.
; Actually, stobj-standin would be called on val.  It is clear that I could
; define this function in raw lisp: look in *the-live-state* to determine how
; to abbreviate val and then just do it.  But what would be the logical
; definition of it?  We could leave it undefined, or defined to be an undefined
; function.  Until we admit the whole ACL2 system :logically, we could even
; define it in the logic to be t even though it really returned something else,
; since as a :program its logical definition is irrelevant.  But at the moment
; I don't think ACL2 has a precedent for such a function and I don't think
; user-specified stobj abbreviation is justification enough for doing it.

; End of Essay on Abbreviating Live Stobjs

; Now we lay down some macros that help with the efficiency of the FMT
; functions, by making it easy to declare various formals and function values
; to be fixnums.  See the Essay on Fixnum Declarations.

(defmacro mv-letc (vars form body)
  `(mv-let ,vars ,form
           (declare (type (signed-byte 30) col))
           ,body))

(defmacro er-hard-val (val &rest args)

; Use (er-hard-val val ctx str ...) instead of (er hard? ctx str ...)
; when there is an expectation on the return type, which should be the
; type of val.  Compilation with the cmulisp compiler produces many
; warnings if we do not use some such device.

  `(prog2$ (er hard? ,@args)
           ,val))

(defmacro the-fixnum! (n ctx)

; See also the-half-fixnum!.

  (let ((upper-bound (fixnum-bound)))
    (declare (type (signed-byte 30) upper-bound))
    (let ((lower-bound (- (1+ upper-bound))))
      (declare (type (signed-byte 30) lower-bound))
      `(the-fixnum
        (let ((n ,n))
          (if (and (<= n ,upper-bound)
                   (>= n ,lower-bound))
              n
            (er-hard-val 0 ,ctx
                         "The object ~x0 is not a fixnum ~
                          (precisely:  not a (signed-byte 30))."
                         n)))))))

(defmacro the-half-fixnum! (n ctx)

; Same as the-fixnum!, but leaves some room.

  (let ((upper-bound (floor (fixnum-bound) 2))) ; (1- (expt 2 28))
    (declare (type (signed-byte 29) upper-bound))
    (let ((lower-bound (- (1+ upper-bound))))
      (declare (type (signed-byte 29) lower-bound))
      `(the-fixnum
        (let ((n ,n))
          (if (and (<= n ,upper-bound)
                   (>= n ,lower-bound))
              n
            (er-hard-val 0 ,ctx
                         "The object ~x0 is not a `half-fixnum' ~
                          (precisely:  not a (signed-byte 29))."
                         n)))))))

(defmacro the-unsigned-byte! (bits n ctx)
  `(the (unsigned-byte ,bits)
        (let ((n ,n) (bits ,bits))
          (if (unsigned-byte-p bits n)
              n
            (er-hard-val 0 ,ctx
                         "The object ~x0 is not an (unsigned-byte ~x1)."
                         n bits)))))

(defmacro the-string! (s ctx)
  `(if (stringp ,s)
       (the string ,s)
     (er-hard-val "" ,ctx
                  "Not a string:  ~s0."
                  ,s)))

(defun xxxjoin-fixnum (fn args root)

; This is rather like xxxjoin, but we wrap the-fixnum around all
; arguments.

  (declare (xargs :guard (true-listp args)))
  (if (cdr args)
      (list 'the-fixnum
            (list fn
                  (list 'the-fixnum (car args))
                  (xxxjoin-fixnum fn (cdr args) root)))
    (if args ; one arg
        (list 'the-fixnum (car args))
      root)))

(defmacro +f (&rest args)
  (xxxjoin-fixnum '+ args 0))

(defmacro -f (arg1 &optional arg2)
  (if arg2
      `(the-fixnum (- (the-fixnum ,arg1)
                      (the-fixnum ,arg2)))
    `(the-fixnum (- (the-fixnum ,arg1)))))

(defmacro 1-f (x)
  (list 'the-fixnum
        (list '1- (list 'the-fixnum x))))

(defmacro 1+f (x)
  (list 'the-fixnum
        (list '1+ (list 'the-fixnum x))))

(defmacro charf (s i)
  (list 'the 'character
        (list 'char s i)))

(defmacro *f (&rest args)
  (xxxjoin-fixnum '* args 1))

; Essay on the ACL2 Prettyprinter

; The ACL2 prettyprinter is a two pass, linear time, exact prettyprinter.  By
; "exact" we mean that if it has a page of width w and a big enough form, it
; will guarantee to use all the columns, i.e., the widest line will end in
; column w.  The algorithm dates from about 1971 -- virtually the same code was
; in the earliest Edinburgh Pure Lisp Theorem Prover.  This approach to
; prettyprinting was invented by Bob Boyer; see
; http://www.cs.utexas.edu/~boyer/pretty-print.pdf.  Most prettyprinters are
; quadratic and inexact.

; The secret to this method is to make two linear passes, ppr1 and ppr2.  The
; first pass builds a data structure, called a ``ppr tuple,'' that tells the
; second pass how to print.

; Some additional general principles of our prettyprinter are
; (i)    Print flat whenever possible.

; (ii)   However, don't print flat argument lists of length over 40; they're
;        too hard to parse.  (But this can be overridden by state global
;        ppr-flat-right-margin.)

; (iii)  Atoms and eviscerated things (which print like atoms, e.g., `<world>')
;        may be printed on a single line.

; (iv)   But parenthesized expressions should not be printed on a line with any
;        other argument (unless the whole form fits on the line).  Thus we may
;        produce:
;        `(foo (bar a) b c d)'
;        and
;        `(foo a b
;              c d)'
;        But we never produce
;        `(foo (bar a) b
;              c d)'
;        preferring instead
;        `(foo (bar a)
;              b c d)'
;        It is our belief that parenthesized expressions are hard to parse and
;        after doing so the eye tends to miss little atoms (like b above)
;        hiding in their shadows.

; To play with ppr we recommend executing this form:

; (ppr2 (ppr1 x (print-base) (print-radix) 30 0 state t)
;       0 *standard-co* state t)

; This will prettyprint x on a page of width 30, assuming that printing starts
; in column 0.  To see the ppr tuple that drives the printer, just evaluate the
; inner ppr1 form,
; (ppr1 x (print-base) (print-radix) 30 0 state nil).

; The following test macro is handy.  A typical call of the macro is

; (test 15 (foo (bar x) (mum :key1 val1 :key2 :val2)))

; Note that x is not evaluated.  If you want to evaluate x and ppr the value,
; use

;   (testfn 10
;           (eviscerate-simple `(foo (bar x)
;                             (mum :key1 :val1 :key2 :val2)
;                             ',(w state))
;                       nil nil ; print-level and print-length
;                       (world-evisceration-alist state nil)
;                       nil
;                       nil)
;           state)

; Note that x may be eviscerated, i.e., eviscerated objects in x are printed in
; their short form, not literally.

;   (defun testfn (d x state)
;     (declare (xargs :mode :program :stobjs (state)))
;     (let ((tuple (ppr1 x (print-base) (print-radix) d 0 state t)))
;       (pprogn
;        (fms "~%Tuple: ~x0~%Output:~%" (list (cons #\0 tuple))
;             *standard-co* state nil)
;        (ppr2 tuple 0 *standard-co* state t)
;        (fms "~%" nil *standard-co* state nil))))
;
;   (defmacro test (d x)

; Ppr tuples record enough information about the widths of various forms so
; that it can be computed without having to recompute any part of it and so
; that the second pass can print without having to count characters.

; A ppr tuple has the form (token n . z).  In the display below, the variables
; ti represent ppr tuples and the variables xi represent objects to be printed
; directly.  Any xi could an eviscerated object, a list whose car is the
; evisceration mark.

; (FLAT n x1 ... xk) - Print the xi, separated by spaces, all on one
;                      line. The total width of output will be n.
;                      Note that k >= 1.  Note also that such a FLAT
;                      represents k objects.  A special case is (FLAT
;                      n x1), which represents one object.  We make
;                      this observation because sometimes (in
;                      cons-ppr1) we `just know' that k=1 and the
;                      reason is: we know the FLAT we're holding
;                      represents a single object.

; (FLAT n x1... . xk)- Print the xi, separated by spaces, with xk
;                      separated by `. ', all on one line.  Here xk
;                      is at atom or an eviscerated object.

; (FLAT n . xk)      - Here, xk is an atom (or an eviscerated object).
;                      Print a dot, a space, and xk.  The width will
;                      be n.  Note that this FLAT does not actually
;                      represent an object.  That is, no Lisp object
;                      prints as `. xk'.

; Note: All three forms of FLAT are really just (FLAT n . x) where x is a
; possibly improper list and the elements of x (and its final cdr) are printed,
; separated appropriately by spaces or dot.

; (MATCHED-KEYWORD n x1)
;                    - Exactly like (FLAT n x1), i.e., prints x1,
;                      but by virtue of being different from FLAT
;                      no other xi's are ever added.  In this tuple,
;                      x1 is always a keyword and it will appear on
;                      a line by itself.  Its associated value will
;                      appear below it in the column because we tried
;                      to put them on the same line but we did not have
;                      room.

; (DOT 1)            - Print a dot.

; (QUOTE n . t1)     - Print a single-quote followed by pretty-
;                      printing the ppr tuple t1.

; (WIDE n t1 t2 ...) - Here, t1 is a FLAT tuple of width j.  We
;                      print an open paren, the contents of t1, a
;                      space, and then we prettyprint each of the
;                      remaining ti in a column.  When we're done, we
;                      print a close paren.  The width of the longest
;                      line we will print is n.

; (i n t1 ...)       - We print an open paren, prettyprint t1, then
;                      do a newline.  Then we prettyprint the
;                      remaining ti in the column that is i to the
;                      right of the paren.  We conclude with a close
;                      paren.  The width of the longest line we will
;                      print is n.  We call this an `indent tuple'.

; (KEYPAIR n t1 . t2)- Here, t1 is a FLAT tuple of width j.  We print
;                      t1, a space, and then prettyprint t2.  The
;                      length of the longest line we will print is n.

; The sentences "The length of the longest line we will print is n."
; bears explanation.  Consider

; (FOO (BAR X)
;      (MUMBLE Y)
;      Z)
;|<- 15 chars  ->|
; 123456789012345

; The length of the longest line, n, is 15.  That is, the length of the longest
; line counts the spaces from the start of the printing.  In the case of a
; KEYPAIR tuple:

; :KEY (FOO
;       (BAR X)
;       Y)
;|<- 13      ->|

; we count the spaces from the beginning of the keyword.  That is, we consider
; the whole block of text.

; Below we print test-term in two different widths, and display the ppr tuple
; that drives each of the two printings.

; (assign test-term
;         '(FFF (GGG (HHH (QUOTE (A . B))))
;               (III YYY ZZZ)))
;
;
; (ppr2 (ppr1 (@ test-term) (print-base) (print-radix) 30 0 state nil) 0
;       *standard-co* state nil)
; ; =>
; (FFF (GGG (HHH '(A . B)))          (WIDE 25 (FLAT 3 FFF)
;      (III YYY ZZZ))                         (FLAT 20 (GGG (HHH '(A . B))))
;                                             (FLAT 14 (III YYY ZZZ)))
; <-          25         ->|
;
; (ppr2 (ppr1 (@ test-term) (print-base) (print-radix) 20 0 state nil) 0
;       *standard-co* state nil)
; ; =>
; (FFF                               (1 20 (FLAT 3 FFF)
;  (GGG                                    (4 19 (FLAT 3 GGG)
;      (HHH '(A . B)))                           (FLAT 15 (HHH '(A . B))))
;  (III YYY ZZZ))                          (FLAT 14 (III YYY ZZZ)))
;
; <-       20       ->|

; The function cons-ppr1, below, is the first interesting function in the nest.
; We want to build a tuple to print a given list form, like a function call.
; We basically get the tuple for the car and a list of tuples for the cdr and
; then use cons-ppr1 to combine them.  The resulting list of tuples will be
; embedded in either a WIDE or an indent tuple.  Thus, this list of tuples we
; will create describes a column of forms.  The number of items in that column
; is not necessarily the same as the number of arguments of the function call.
; For example, the term (f a b c) might be prettyprinted as
; (f a
;    b c)
; where b and c are printed flat on a single line.  Thus, the three arguments
; of f end up being described by a list of two tuples, one for a and another
; for b and c.

; To form lists of tuples we just use cons-ppr1 to combine the tuples we get
; for each element.

; Let x and lst be, respectively, a ppr tuple for an element and a list of
; tuples for list of elements.  Think of lst as describing a column of forms.
; Either x can become another item that column, or else x can be incorporated
; into the first item in that column.  For example, suppose x will print as X
; and lst will print as a column containing y1, y2, etc.  Then we have this
; choice for printing x and lst:

; lengthened column          lengthened first row
; x                          x y1
; y1                         y2
; ...                        ...

; We get the `lengthened column' behavior if we just cons x onto lst.  We get
; the `lengthened row' behavior if we merge the tuples for x and y1.  But we
; only merge if they both print flat.

; Essay on the Printing of Dotted Pairs and

; It is instructive to realize that we print a dotted pair as though it were a
; list of length 3 and the dot was just a normal argument.

; In the little table below I show, for various values of d, two things: the
; characters output by

; (ppr2 (ppr1 `(xx . yy) (print-base) (print-radix) d 0 state nil)
;       0 *standard-co* state nil)

; and the ppr tuple produced by the ppr1 call.
;
; d         output                 ppr tuple

;        |<-  9  ->|

; 9       (XX . YY)              (FLAT 9 (XX . YY))

; 8       (XX                    (3 8 (FLAT 2 XX) (FLAT 5 . YY))
;            . YY)

; 7       (XX                    (2 7 (FLAT 2 XX) (FLAT 5 . YY))
;           . YY)

; 6       (XX                    (1 6 (FLAT 2 XX) (FLAT 5 . YY))
;          . YY)

; 5       (XX                    (2 5 (FLAT 2 XX) (DOT 1) (FLAT 3 YY))
;           .
;           YY)

; 4       (XX                    (1 4 (FLAT 2 XX) (DOT 1) (FLAT 3 YY))
;          .
;          YY)

; The fact that the dot is not necessarily connected to (on the same line as)
; the atom following it is the reason we have the (DOT 1) tuple.  We have to
; represent the dot so that its placement is first class.  So when we're
; assembling the tuple for a list, we cdr down the list using cons-ppr1 to put
; together the tuple for the car with the tuple for the cdr.  If we reach a
; non-nil cdr, atm, we call cons-ppr1 on the dot tuple and the tuple
; representing the atm.  Depending on the width we have, this may produce (FLAT
; n . atm) which attaches the dot to the atm, or ((DOT 1) (FLAT n atm)) which
; leaves the dot on a line by itself.

; We want keywords to appear on new lines.  That means if the first element of
; lst is a keyword, don't merge (unless x is one too).

; BUG
; ACL2 p!>(let ((x '(foo bigggggggggggggggg . :littlllllllllllllle)))
;          (ppr2 (ppr1 x (print-base) (print-radix) 40 0 state nil)
;                0 *standard-co* state nil))
; (x   = (DOT 1)
; lst = ((FLAT 21 :LITTLLLLLLLLLLLLLLE))
; val = ((FLAT 23 . :LITTLLLLLLLLLLLLLLE)))
;
; HARD ACL2 ERROR in CONS-PPR1:  I thought I could force it!

(defmacro ppr-flat-right-margin ()
  '(f-get-global 'ppr-flat-right-margin state))

(defun set-ppr-flat-right-margin (val state)
  (if (posp val)
      (f-put-global 'ppr-flat-right-margin val state)
    (prog2$ (illegal 'set-ppr-flat-right-margin
                     "Set-ppr-flat-right-margin takes a positive integer ~
                      argument, unlike ~x0."
                     (list (cons #\0 val)))
            state)))

; Note: In the function below, column is NOT a number!  Often in this code,
; ``col'' is used to represent the position of the character column into which
; we are printing.  But ``column'' is a list of ppr tuples.

(defun keyword-param-valuep (tuple eviscp)

; We return t iff tuple represents a single object that could plausibly be the
; value of a keyword parameter.  The (or i ii iii iv) below checks that tuple
; represents a single object, either by being (i) a FLAT tuple listing exactly
; one object (ii) a QUOTE tuple, (iii) a WIDE tuple, or (iv) an indent tuple.
; The only other kinds of tuples are KEYPAIR tuples, FLAT tuples representing
; dotted objects `. atm', FLAT tuples representing several objects `a b c', and
; MATCHED-KEYWORD tuples representing keywords whose associated values are on
; the next line.  These wouldn't be provided as the value of a keyword
; argument.

  (or (and (eq (car tuple) 'flat)
           (not (or (atom (cddr tuple)) ; tuple is `. atm'
                    (evisceratedp eviscp (cddr tuple))))
           (null (cdr (cddr tuple))))
      (eq (car tuple) 'quote)
      (eq (car tuple) 'wide)
      (integerp (car tuple))))

(defun cons-ppr1 (x column width ppr-flat-right-margin eviscp)

; Here, x is a ppr tuple representing either a dot or a single object and
; column is a list of tuples corresponding to a list of objects (possibly a
; list of length greater than that of column).  Intuitively, column will print
; as a column of objects and we want to add x to that column, either by
; extending the top row or adding a new row.  In the most typical case, x might
; be (FLAT 3 ABC) and column is ((FLAT 7 DEF GHI) (...)).  Thus our choices
; would be to produce

; lengthened column          lengthened first row
; ABC                        ABC DEF GHI
; DEF GHI                    (...)
; (...)

; It is also here that we deal specially with keywords.  If x is
; (FLAT 3 :ABC) and column is ((...) (...)) then we have the choice:

; lengthened column          lengthened first row
; :ABC                       :ABC (...)
; (...)                      (...)
; (...)

; The default behavior is always to lengthen the column, which is just to cons
; x onto column.

  (cond
   ((and (eq (car x) 'flat)

; Note: Since x represents a dot or an object, we know that it is not of the
; form (FLAT n . atm).  Thus, (cddr x) is a list of length 1 containing a
; single (possibly eviscerated) object, x1.  If that object is an atom (or
; prints like one) we'll consider merging it with whatever else is on the first
; row.

         (or (atom (car (cddr x)))
             (evisceratedp eviscp (car (cddr x))))
         (consp column))

    (let ((x1 (car (cddr x)))
          (row1 (car column)))

; We know x represents the atom x1 (actually, x1 may be an eviscerated object,
; but if so it prints flat like an atom, e.g., `<world>').  Furthermore, we
; know column is non-empty and so has a first element, e.g., row1.

      (cond
       ((keywordp x1)

; So x1 is a keyword.  Are we looking at a keypair?  We are if row1 represents
; a single value.  By a ``single value'' we mean a single object that can be
; taken as the value of the keyword x1.  If row1 represents a sequence of more
; than one object, e.g., (FLAT 5 a b c), then we are not in a keypair situation
; because keyword argument lists must be keyword/value pairs all the way down
; and we form these columns bottom up, so if b were a keyword in the proper
; context, we would have paired it with c as keypair, not merged it, or we
; would have put it in a MATCHED-KEYWORD, indicating that its associated value
; is below it in the column.  If row1 does not represent a single value we act
; just like x1 had not been a keyword, i.e., we try to merge it with row1.
; This will shut down subsequent attempts to create keypairs above us.

        (cond
         ((and (keyword-param-valuep row1 eviscp)
               (or (null (cdr column))
                   (eq (car (cadr column)) 'keypair)
                   (eq (car (cadr column)) 'matched-keyword)))

; So x1 is a keyword, row1 represents a keyword parameter value, and
; the rest of the column represents keyword/value pairs.  The last
; test is made by just checking the item on the column below row1.  It
; would only be a keyword/value pair if the whole column consisted of
; those.  We consider making a keypair of width n = width of key, plus
; space, plus width of widest line in row1.  Note that we don't mind
; this running over the standard 40 character max line length because
; it is so iconic.

          (let ((n (+ (cadr x) (+ 1 (cadr row1)))))
            (cond ((<= n width)
                   (cons
                    (cons 'keypair (cons n (cons x row1)))
                    (cdr column)))

; Otherwise, we put x on a newline and leave the column as it was.  Note that
; we convert x from a FLAT to a MATCHED-KEYWORD, so insure that it stays on a
; line by itself and to keyword/value pairs encountered above us in the
; bottom-up processing to be paired with KEYPAIR.

                  (t (cons (cons 'MATCHED-KEYWORD (cdr x))
                           column)))))

; In this case, we are not in the context of a keyword/value argument even
; though x is a keyword.  So we act just like x is not a keyword and see
; whether we can merge it with row1.  We merge only if row1 is FLAT already and
; the width of the merged row is acceptable.  Even if row1 prints as `. atm' we
; will merge, giving rise to such displays as

; (foo a b c
;      d e f . atm)

         ((eq (car row1) 'flat)
          (let ((n (+ (cadr x) (+ 1 (cadr row1)))))
            (cond ((and (<= n ppr-flat-right-margin) (<= n width))
                   (cons
                    (cons 'flat (cons n (cons x1 (cddr row1))))
                    (cdr column)))
                  (t (cons x column)))))
         (t (cons x column))))

; In this case, x1 is not a keyword.  But it is known to print in atom-like
; way, e.g., `ABC' or `<world>'.  So we try a simple merge following the same
; scheme as above.

       ((eq (car row1) 'flat)
        (let ((n (+ (cadr x) (+ 1 (cadr row1)))))
          (cond ((and (<= n ppr-flat-right-margin) (<= n width))
                 (cons
                  (cons 'flat (cons n (cons x1 (cddr row1))))
                  (cdr column)))
                (t (cons x column)))))
       (t (cons x column)))))
   ((and (eq (car x) 'dot)
         (consp column))
    (let ((row1 (car column)))
      (cond ((eq (car row1) 'flat)

; In this case we know (car (cddr row1)) is an atom (or an eviscerated object)
; and it becomes the cddr of the car of the answer, which puts the dot on the
; same line as the terminal cdr.

             (let ((n (+ (cadr x) (+ 1 (cadr row1)))))
               (cond ((and (<= n ppr-flat-right-margin) (<= n width))
                      (cons
                       (cons 'flat
                             (cons n (car (cddr row1))))
                       (cdr column)))
                     (t (cons x column)))))
            (t (cons x column)))))

; In this case, x1 does not print flat.  So we add a new row.

   (t (cons x column))))

(defun flsz-integer (x print-base acc)
  (declare (type (unsigned-byte 5) print-base)
           (type (signed-byte 30) acc)
           (xargs :guard (print-base-p print-base)))
  (the-fixnum
   (cond ((< x 0)
          (flsz-integer (- x) print-base (1+f acc)))
         ((< x print-base) (1+f acc))
         (t (flsz-integer (truncate x print-base) print-base (1+f acc))))))

(defun flsz-atom (x print-base print-radix acc state)
  (declare (type (unsigned-byte 5) print-base)
           (type (signed-byte 30) acc))
  (the-fixnum
   (cond ((> acc (the (signed-byte 30) 100000))

; In order to make it very simple to guarantee that flsz and flsz-atom return
; fixnums, we ensure that acc is small enough below.  We could certainly
; provide a much more generous bound, but 100,000 seems safe at the moment!

          100000)
         ((integerp x)
          (flsz-integer x
                        print-base
                        (cond ((null print-radix)
                               acc)
                              ((int= print-base 10) ; `.' suffix
                               (+f 1 acc))
                              (t ; #b, #o, or #x prefix
                               (+f 2 acc)))))
         ((symbolp x)

; For symbols we add together the length of the "package part" and the symbol
; name part.  We include the colons in the package part.

          (+f (cond
               ((keywordp x) (1+f acc))
               ((symbol-in-current-package-p x state)
                acc)
               (t
                (let ((p (symbol-package-name x)))
                  (cond ((needs-slashes p state)
                         (+f 4 acc (the-half-fixnum! (length p)
                                                     'flsz-atom)))
                        (t (+f 2 acc (the-half-fixnum! (length p)
                                                       'flsz-atom)))))))
              (let ((s (symbol-name x)))
                 (cond ((needs-slashes s state)
                        (+f 2 (the-half-fixnum! (length s) 'flsz-atom)))
                       (t (+f (the-half-fixnum! (length s) 'flsz-atom)))))))
         ((rationalp x)
          (flsz-integer (numerator x)
                        print-base
                        (flsz-integer (denominator x)
                                      print-base
                                      (cond ((null print-radix)
                                             (+f 1 acc))
                                            ((int= print-base 10) ; #10r prefix
                                             (+f 5 acc))
                                            (t ; #b, #o, or #x prefix
                                             (+f 3 acc))))))
         ((complex-rationalp x)
          (flsz-atom (realpart x)
                     print-base
                     print-radix
                     (flsz-atom (imagpart x) print-base print-radix acc state)
                     state))
         ((stringp x)
          (+f 2 acc (the-half-fixnum! (length x) 'flsz-atom)))
         ((characterp x)
          (+f acc
              (cond ((eql x #\Newline) 9)
                    ((eql x #\Rubout) 8)
                    ((eql x #\Space) 7)
                    ((eql x #\Page) 6)
                    ((eql x #\Tab) 5)
                    (t 3))))
         (t 0))))

(defun flsz1 (x print-base print-radix j maximum state eviscp)

; Actually, maximum should be of type (signed-byte 29).

  (declare (type (unsigned-byte 5) print-base)
           (type (signed-byte 30) j maximum))
  (the-fixnum
   (cond ((> j maximum) j)
         ((atom x) (flsz-atom x print-base print-radix j state))
         ((evisceratedp eviscp x)
          (+f j (the-half-fixnum! (length (cdr x)) 'flsz)))
         ((atom (cdr x))
          (cond ((null (cdr x))
                 (flsz1 (car x) print-base print-radix (+f 2 j) maximum state
                        eviscp))
                (t (flsz1 (cdr x)
                          print-base
                          print-radix
                          (flsz1 (car x) print-base print-radix (+f 5 j)
                                 maximum state eviscp)
                          maximum state eviscp))))
         ((and (eq (car x) 'quote)
               (consp (cdr x))
               (null (cddr x)))
          (flsz1 (cadr x) print-base print-radix (+f 1 j) maximum state
                 eviscp))
         (t (flsz1 (cdr x)
                   print-base
                   print-radix
                   (flsz1 (car x) print-base print-radix (+f 1 j) maximum state
                          eviscp)
                   maximum state eviscp)))))

(defun output-in-infixp (state)
  (let ((infixp (f-get-global 'infixp state)))
    (or (eq infixp t) (eq infixp :out))))

(defun flatsize-infix (x print-base print-radix termp j max state eviscp)

; Suppose that printing x flat in infix notation causes k characters to come
; out.  Then we return j+k.  All answers greater than max are equivalent.

; If you think of j as the column into which you start printing flat, then this
; returns the column you'll print into after printing x.  If that column
; exceeds max, which is the right margin, then it doesn't matter by how far it
; exceeds max.

; In our $ infix notation, flat output has two extra chars in it, the $ and
; space.  But note that we use infix output only if infixp is t or :out.

  (declare (ignore termp))
  (+ 2 (flsz1 x print-base print-radix j max state eviscp)))

(defun flsz (x termp j maximum state eviscp)
  (cond ((output-in-infixp state)
         (flatsize-infix x (print-base) (print-radix) termp j maximum state
                         eviscp))
        (t (flsz1 x (print-base) (print-radix) j maximum state eviscp))))

(defun max-width (lst maximum)
  (cond ((null lst) maximum)
        ((> (cadr (car lst)) maximum)
         (max-width (cdr lst) (cadr (car lst))))
        (t (max-width (cdr lst) maximum))))

(mutual-recursion

(defun ppr1 (x print-base print-radix width rpc state eviscp)

; We create a ppr tuple for x, i.e., a list structure that tells us how to
; prettyprint x, in a column of the given width.  Rpc stands for `right paren
; count' and is the number of right parens that will follow the printed version
; of x.  For example, in printing the x in (f (g (h x)) u) there will always be
; 2 right parens after it.  So we cannot let x use the entire available width,
; only the width-2.  Rpc would be 2.  Eviscp indicates whether we are to think
; of evisc marks as printing as atom-like strings or whether they're just
; themselves as data.

  (declare (type (signed-byte 30) print-base width rpc))
  (let ((sz (flsz1 x print-base print-radix rpc width state eviscp)))
    (declare (type (signed-byte 30) sz))
    (cond ((or (atom x)
               (evisceratedp eviscp x)
               (and (<= sz width)
                    (<= sz (ppr-flat-right-margin))))
           (cons 'flat (cons sz (list x))))
          ((and (eq (car x) 'quote)
                (consp (cdr x))
                (null (cddr x)))
           (let* ((x1 (ppr1 (cadr x) print-base print-radix (+f width -1) rpc state
                            eviscp)))
             (cons 'quote (cons (+ 1 (cadr x1)) x1))))
          (t
           (let* ((x1 (ppr1 (car x) print-base print-radix (+f width -1)
                            (the-fixnum (if (null (cdr x)) (+ rpc 1) 0))
                            state eviscp))

; If the fn is a symbol (or eviscerated, which we treat as a symbol), then the
; hd-sz is the length of the symbol.  Else, hd-sz is nil.  Think of (null
; hd-sz) as meaning "fn is a lambda expession".

                  (hd-sz (cond ((or (atom (car x))
                                    (evisceratedp eviscp (car x)))
                                (cadr x1))
                               (t nil)))

; When printing the cdr of x, give each argument the full width (minus 1 for
; the minimal amount of indenting).  Note that x2 contains the ppr tuples for
; the car and the cdr.

                  (x2 (cons x1
                            (ppr1-lst (cdr x) print-base print-radix (+f width -1)
                                      (+f rpc 1) state eviscp)))

; If the fn is a symbol, then we get the maximum width of any single argument.
; Otherwise, we get the maximum width of the fn and its arguments.

                  (maximum (cond (hd-sz (max-width (cdr x2) -1))
                                 (t (max-width x2 -1)))))

             (cond ((null hd-sz)

; If the fn is lambda, we indent the args by 1 and report the width of the
; whole to be one more than the maximum computed above.

                    (cons 1 (cons (+ 1 maximum) x2)))
                   ((<= (+ hd-sz (+ 2 maximum)) width)

; We can print WIDE if we have room for an open paren, the fn, a space, and the
; widest argument.

                    (cons 'wide
                          (cons (+ hd-sz (+ 2 maximum)) x2)))
                   ((< maximum width)

; If the maximum is less than the width, we can do exact indenting of the
; arguments to make the widest argument come out on the right margin.  This
; exactness property is one of the things that makes this algorithm produce
; such beautiful output: we get the largest possible indentation, which makes
; it easy to identify peer arguments.  How much do we indent?  width-maximum
; will guarantee that the widest argument ends on the right margin.  However,
; we believe that it is more pleasing if argument columns occur at regular
; indents.  So we limit our indenting to 5 and just give up the white space
; over on the right margin.  Note that we compute the width of the whole term
; accordingly.

                    (cons (min 5 (+ width (- maximum)))
                          (cons (+ maximum (min 5 (+ width (- maximum))))
                                x2)))

; If maximum is not less than width, we indent by 1.

                   (t (cons 1 (cons (+ 1 maximum) x2)))))))))


; The next function computes a ppr tuple for each element of lst.  Typically
; these are all arguments to a function.  But of course, we prettyprint
; arbitrary constants and so have to handle the case that the list is not a
; true-list.

; If you haven't read about cons-ppr1, above, do so now.

(defun ppr1-lst (lst print-base print-radix width rpc state eviscp)

  (declare (type (signed-byte 30) print-base width rpc))
  (cond ((atom lst)

; If the list is empty and null, then nothing is printed (besides the parens
; which are being accounted for otherwise).  If the list is terminated by some
; non-nil atom, we will print a dot and the atom.  We do that by merging a dot
; tuple into the flat for the atom, if there's room on the line, using
; cons-ppr1.  Where this merged flat will go, i.e., will it be indented under
; the car as happens in the Essay on the Printing of Dotted Pairs, is the
; concern of ppr1-lst, not the cons-ppr1.  The cons-ppr1 below just produces a
; merged flat containing the dot, if the width permits.

         (cond ((null lst) nil)
               (t (cons-ppr1 '(dot 1)
                             (list (ppr1 lst print-base print-radix width rpc
                                         state eviscp))
                             width (ppr-flat-right-margin) eviscp))))

; The case for an eviscerated terminal cdr is handled the same way.

        ((evisceratedp eviscp lst)
         (cons-ppr1 '(dot 1)
                    (list (ppr1 lst print-base print-radix width rpc state
                                eviscp))
                    width (ppr-flat-right-margin) eviscp))

; If the list is a true singleton, we just use ppr1 and we pass it the rpc that
; was passed in because this last item will be followed by that many parens on
; the same line.

        ((null (cdr lst))
         (list (ppr1 (car lst) print-base print-radix width rpc state eviscp)))

; Otherwise, we know that the car is followed by more elements.  So its rpc is
; 0.

        (t (cons-ppr1 (ppr1 (car lst) print-base print-radix width 0 state
                            eviscp)
                      (ppr1-lst (cdr lst) print-base print-radix width rpc
                                state eviscp)
                      width (ppr-flat-right-margin) eviscp))))

)

(defun newline (channel state)
  (princ$ #\Newline channel state))

(defun fmt-hard-right-margin (state)
  (the-fixnum
   (f-get-global 'fmt-hard-right-margin state)))

(defun fmt-soft-right-margin (state)
  (the-fixnum
   (f-get-global 'fmt-soft-right-margin state)))

(defun set-fmt-hard-right-margin (n state)
  (cond
   ((and (integerp n)
         (< 0 n))
    (f-put-global 'fmt-hard-right-margin
                  (the-half-fixnum! n 'set-fmt-hard-right-margin)
                  state))
   (t (let ((err (er hard 'set-fmt-hard-right-margin
                     "The fmt-hard-right-margin must be a positive ~
                      integer, but ~x0 is not."
                     n)))
        (declare (ignore err))
        state))))

(defun set-fmt-soft-right-margin (n state)
  (cond
   ((and (integerp n)
         (< 0 n))
    (f-put-global 'fmt-soft-right-margin
                  (the-half-fixnum! n 'set-fmt-soft-right-margin)
                  state))
   (t (let ((err (er hard 'set-fmt-soft-right-margin
                     "The fmt-soft-right-margin must be a positive ~
                      integer, but ~x0 is not."
                     n)))
        (declare (ignore err))
        state))))

(defun write-for-read (state)
  (f-get-global 'write-for-read state))

(defun spaces1 (n col hard-right-margin channel state)
  (declare (type (signed-byte 30) n col hard-right-margin))
  (cond ((<= n 0) state)
        ((> col hard-right-margin)
         (pprogn (if (write-for-read state)
                     state
                   (princ$ #\\ channel state))
                 (newline channel state)
                 (spaces1 n 0 hard-right-margin channel state)))
        (t (pprogn (princ$ #\Space channel state)
                   (spaces1 (1-f n) (1+f col) hard-right-margin channel
                            state)))))

; The use of *acl2-built-in-spaces-array* to circumvent the call to spaces1
; under spaces has saved about 25% in GCL and a little more than 50% in
; Allegro.

(defun make-spaces-array-rec (n acc)
  (if (zp n)
      (cons (cons 0 "") acc)
    (make-spaces-array-rec
     (1- n)
     (cons
      (cons n
            (coerce (make-list n :initial-element #\Space) 'string))
      acc))))

(defun make-spaces-array (n)
  (compress1
   'acl2-built-in-spaces-array
   (cons `(:HEADER :DIMENSIONS (,(1+ n))
                   :MAXIMUM-LENGTH ,(+ 2 n)
                   :DEFAULT nil ; should be ignored
                   :NAME acl2-built-in-spaces-array)
         (make-spaces-array-rec n nil))))

(defconst *acl2-built-in-spaces-array*

; Keep the 200 below in sync with the code in spaces.

  (make-spaces-array 200))

(defun spaces (n col channel state)
  (declare (type (signed-byte 30) n col))
  (let ((hard-right-margin (fmt-hard-right-margin state))
        (result-col (+f n col)))
    (declare (type (signed-byte 30) hard-right-margin result-col))
    (if (and (<= result-col hard-right-margin)

; Keep the 200 below in sync with the code in *acl2-built-in-spaces-array*.

             (<= n 200))
        ;; actually (1+ hard-right-margin) would do
        (princ$ (aref1 'acl2-built-in-spaces-array
                       *acl2-built-in-spaces-array*
                       n)
                channel state)
      (spaces1 (the-fixnum! n 'spaces)
               (the-fixnum col)
               hard-right-margin
               channel state))))

(mutual-recursion

(defun flpr1 (x channel state eviscp)
  (cond ((atom x)
         (prin1$ x channel state))
        ((evisceratedp eviscp x)
         (princ$ (cdr x) channel state))
        ((and (eq (car x) 'quote)
              (consp (cdr x))
              (null (cddr x)))
         (pprogn (princ$ #\' channel state)
                 (flpr1 (cadr x) channel state eviscp)))
        (t (pprogn (princ$ #\( channel state)
                   (flpr11 x channel state eviscp)))))

(defun flpr11 (x channel state eviscp)
  (pprogn
   (flpr1 (car x) channel state eviscp)
   (cond ((null (cdr x)) (princ$ #\) channel state))
         ((or (atom (cdr x))
              (evisceratedp eviscp (cdr x)))
          (pprogn
           (princ$ " . " channel state)
           (flpr1 (cdr x) channel state eviscp)
           (princ$ #\) channel state)))
         (t (pprogn
             (princ$ #\Space channel state)
             (flpr11 (cdr x) channel state eviscp))))))

)

#-acl2-loop-only
(defun-one-output print-flat-infix (x termp file eviscp)

; Print x flat (without terpri's) in infix notation to the open output
; stream file.  Give special treatment to :evisceration-mark iff
; eviscp.  We only call this function if flatsize-infix assures us
; that x will fit on the line.  See the Essay on Evisceration in this
; file to details on that subject.

  (declare (ignore termp eviscp))
  (let ((*print-case* :downcase)
        (*print-pretty* nil))
    (princ "$ " file)
    (prin1 x file)))

(defun flpr (x termp channel state eviscp)
  #+acl2-loop-only
  (declare (ignore termp))
  #-acl2-loop-only
  (cond ((and (live-state-p state)
              (output-in-infixp state))
         (print-flat-infix x termp
                           (get-output-stream-from-channel channel)
                           eviscp)
         (return-from flpr *the-live-state*)))
  (flpr1 x channel state eviscp))

(defun ppr2-flat (x channel state eviscp)

; We print the elements of x, separated by spaces.  If x is a non-nil atom, we
; print a dot and then x.

  (cond ((null x) state)
        ((or (atom x)
             (evisceratedp eviscp x))
         (pprogn (princ$ #\. channel state)
                 (princ$ #\Space channel state)
                 (flpr1 x channel state eviscp)))
        (t (pprogn
            (flpr1 (car x) channel state eviscp)
            (cond ((cdr x)
                   (pprogn (princ$ #\Space channel state)
                           (ppr2-flat (cdr x) channel state eviscp)))
                  (t state))))))

(mutual-recursion

(defun ppr2-column (lst loc col channel state eviscp)

; We print the elements of lst in a column.  The column number is col and we
; assume the print head is currently in column loc, loc <= col.  Thus, to
; indent to col we print col-loc spaces.  After every element of lst but the
; last, we print a newline.

  (cond ((null lst) state)
        (t (pprogn
            (spaces (+ col (- loc)) loc channel state)
            (ppr2 (car lst) col channel state eviscp)
            (cond ((null (cdr lst)) state)
                  (t (pprogn
                      (newline channel state)
                      (ppr2-column (cdr lst) 0 col
                                   channel state eviscp))))))))

(defun ppr2 (x col channel state eviscp)

; We interpret the ppr tuple x.

  (case
    (car x)
    (flat (ppr2-flat (cddr x) channel state eviscp))
    (matched-keyword
     (ppr2-flat (cddr x) channel state eviscp)) ; just like flat!
    (dot (princ$ #\. channel state))
    (quote (pprogn (princ$ #\' channel state)
                   (ppr2 (cddr x) (+ 1 col) channel state eviscp)))
    (keypair (pprogn
              (ppr2-flat (cddr (car (cddr x))) channel state eviscp)
              (princ$ #\Space channel state)
              (ppr2 (cdr (cddr x))
                    (+ col (+ 1 (cadr (car (cddr x)))))
                    channel state eviscp)))
    (wide (pprogn
           (princ$ #\( channel state)
           (ppr2-flat (cddr (car (cddr x))) channel state eviscp)
           (ppr2-column (cdr (cddr x))
                        (+ col (+ 1 (cadr (car (cddr x)))))
                        (+ col (+ 2 (cadr (car (cddr x)))))
                        channel state eviscp)
           (princ$ #\) channel state)))
    (otherwise (pprogn
                (princ$ #\( channel state)
                (ppr2 (car (cddr x)) (+ col (car x)) channel
                      state eviscp)
                (cond ((cdr (cddr x))
                       (pprogn
                        (newline channel state)
                        (ppr2-column (cdr (cddr x))
                                     0
                                     (+ col (car x))
                                     channel state eviscp)
                        (princ$ #\) channel state)))
                      (t (princ$ #\) channel state)))))))
)

; We used to set *fmt-ppr-indentation* below to 5, but it the indentation was
; sometimes odd because when printing a list, some elements could be indented
; and others not.  At any rate, it should be less than the
; fmt-hard-right-margin in order to preserve the invariant that fmt0 is called
; on columns that do not exceed this value.

(defconst *fmt-ppr-indentation* 0)

(defun ppr (x col channel state eviscp)

; If eviscp is nil, then we pretty print x as given.  Otherwise, x has been
; eviscerated and we give special importance to the *evisceration-mark*.  NOTE
; WELL: This function does not eviscerate -- it assumes the evisceration has
; been done if needed.

  (declare (type (signed-byte 30) col))
  (let ((fmt-hard-right-margin (fmt-hard-right-margin state)))
    (declare (type (signed-byte 30) fmt-hard-right-margin))
    (cond
     ((< col fmt-hard-right-margin)
      (ppr2 (ppr1 x (print-base) (print-radix)
                  (+f fmt-hard-right-margin (-f col))
                  0 state eviscp)
            col channel state eviscp))
     (t (let ((er
               (er hard 'ppr
                   "The `col' argument to ppr must be less than value ~
                    of the state global variable ~
                    fmt-hard-right-margin, but ~x0 is not less than ~
                    ~x1."
                   col fmt-hard-right-margin)))
          (declare (ignore er))
          state)))))

(defun scan-past-whitespace (s i maximum)
  (declare (type (signed-byte 30) i maximum)
           (type string s))
  (the-fixnum
   (cond ((< i maximum)
          (cond ((member (charf s i) '(#\Space #\Tab #\Newline))
                 (scan-past-whitespace s (+f i 1) maximum))
                (t i)))
         (t maximum))))

(defun zero-one-or-more (x)
  (let ((n (cond ((integerp x) x)
                 (t (length x)))))
    (case n
          (0 0)
          (1 1)
          (otherwise 2))))

(defun find-alternative-skip (s i maximum)

; This function finds the first character after a list of alternatives.  i is
; the value of find-alternative-stop, i.e., it points to the ~ in the ~/ or ~]
; that closed the alternative used.

; Suppose s is "~#7~[ab~/cd~/ef~]acl2".
;               01234567890123456789
; If i is 11, the answer is 17.
;

  (declare (type (signed-byte 30) i maximum)
           (type string s))
  (the-fixnum
   (cond ((< i maximum)
          (let ((char-s-i (charf s i)))
            (declare (type character char-s-i))
            (case char-s-i
              (#\~
               (let ((char-s-1+i (charf s (1+f i))))
                 (declare (type character char-s-1+i))
                 (case char-s-1+i
                   (#\] (+f 2 i))
                   (#\[ (find-alternative-skip
                         s
                         (find-alternative-skip s (+f 2 i)
                                                maximum)
                         maximum))
                   (otherwise (find-alternative-skip
                               s (+f 2 i) maximum)))))
              (otherwise
               (find-alternative-skip s (+f 1 i) maximum)))))
         (t (er-hard-val 0 'find-alternative-skip
                "Illegal Fmt Syntax -  While looking for the terminating ~
                bracket of a tilde alternative directive in the string ~
                below we ran off the end of the string.~|~%~x0"
                s)))))

(defun find-alternative-start1 (x s i maximum)
  (declare (type (signed-byte 30) x i maximum)
           (type string s))
  (the-fixnum
   (cond ((= x 0) i)
         ((< i maximum)
          (let ((char-s-i (charf s i)))
            (declare (type character char-s-i))
            (case char-s-i
              (#\~
               (let ((char-s-1+-i (charf s (1+f i))))
                 (declare (type character char-s-1+-i))
                 (case char-s-1+-i
                   (#\/ (find-alternative-start1
                         (1-f x) s (+f 2 i)
                         maximum))
                   (#\] (er-hard-val 0 'find-alternative-start1
                            "Illegal Fmt Syntax -- The tilde directive ~
                             terminating at position ~x0 of the string below ~
                             does not have enough alternative clauses.  When ~
                             the terminal bracket was reached we still needed ~
                             ~#1~[~/1 more alternative~/~x2 more ~
                             alternatives~].~|~%~x3"
                            i
                            (zero-one-or-more x)
                            x
                            s))
                   (#\[ (find-alternative-start1
                         x s
                         (find-alternative-skip s (+f 2 i) maximum)
                         maximum))
                   (otherwise
                    (find-alternative-start1
                     x s (+f 2 i) maximum)))))
              (otherwise
               (find-alternative-start1 x s (+f 1 i)
                                        maximum)))))
         (t (er-hard-val 0 'find-alternative-start1
                "Illegal Fmt Syntax -- While searching for the appropriate ~
                alternative clause of a tilde alternative directive in the ~
                string below, we ran off the end of the string.~|~%~x0"
                s)))))

(defun fmt-char (s i j maximum err-flg)
  (declare (type (signed-byte 30) i maximum)

; We only increment i by a small amount, j.

           (type (integer 0 100) j)
           (type string s))
  (the character
       (cond ((< (+f i j) maximum) (charf s (+f i j)))
             (t
              (prog2$ ; return an arbitrary character
               (cond (err-flg
                      (er hard 'fmt-char
                          "Illegal Fmt Syntax.  The tilde directive at ~
                           location ~x0 in the fmt string below requires that ~
                           we look at the character ~x1 further down in the ~
                           string.  But the string terminates at location ~
                           ~x2.~|~%~x3"
                          i j maximum s))
                     (t nil))
               #\a)))))

(defun find-alternative-start (x s i maximum)

; This function returns the index of the first character in the xth
; alternative, assuming i points to the ~ that begins the alternative
; directive.  If x is not an integer, we assume it is a non-empty
; list.  If its length is 1, pick the 0th alternative.  Otherwise,
; pick the 1st.  This means we can test on a list to get a "plural" test.

; Suppose s is "~#7~[ab~/cd~/ef~]acl2".  The indices into s are
;               01234567890123456789
; This function is supposed to be called with i=0.  Suppose register
; 7 contains a 1.  That's the value of x.  This function will return
; 9, the index of the beginning of alternative x.

  (declare (type (signed-byte 30) i maximum)
           (type string s))
  (the-fixnum
   (let ((x (cond ((integerp x) (the-fixnum! x 'find-alternative-start))
                  ((and (consp x)
                        (atom (cdr x)))
                   0)
                  (t 1))))
     (declare (type (signed-byte 30) x))
     (cond ((not (and (eql (the character (fmt-char s i 3 maximum t)) #\~)
                      (eql (the character (fmt-char s i 4 maximum t)) #\[)))
            (er-hard-val 0 'find-alternative-start
                "Illegal Fmt Syntax:  The tilde directive at ~x0 in the ~
                fmt string below must be followed immediately by ~~[. ~
                ~|~%~x1"
                i s))
           (t (find-alternative-start1 x s (+f i 5) maximum))))))

(defun find-alternative-stop (s i maximum)

; This function finds the end of the alternative into which i is
; pointing.  i is usually the first character of the current alternative.
; The answer points to the ~ in the ~/ or ~] closing the alternative.

; Suppose s is "~#7~[ab~/cd~/ef~]acl2".
;               01234567890123456789
; and i is 9.  Then the answer is 11.

  (declare (type (signed-byte 30) i maximum)
           (type string s))
  (the-fixnum
   (cond ((< i maximum)
          (let ((char-s-i (charf s i)))
            (declare (type character char-s-i))
            (case char-s-i
              (#\~ (let ((char-s-1+i (charf s (1+f i))))
                     (declare (type character char-s-1+i))
                     (case char-s-1+i
                       (#\/ i)
                       (#\[ (find-alternative-stop
                             s
                             (find-alternative-skip s (+f 2 i) maximum)
                             maximum))
                       (#\] i)
                       (otherwise (find-alternative-stop
                                   s (+f 2 i) maximum)))))
              (otherwise (find-alternative-stop s (+f 1 i) maximum)))))
         (t (er-hard-val 0 'find-alternative-stop
                "Illegal Fmt Syntax -- While looking for the terminating ~
                slash of a tilde alternative directive alternative clause ~
                in the string below we ran off the end of the string. ~
                ~|~%~x0"
                s)))))

(defun punctp (c)
  (if (member c '(#\. #\, #\: #\; #\? #\! #\) #\]))
      c
    nil))

(defun fmt-tilde-s1 (s i maximum col channel state)
  (declare (type (signed-byte 30) i maximum col)
           (type string s))
  (the2s
   (signed-byte 30)
   (cond ((not (< i maximum))
          (mv col state))
         ((and (> col (fmt-hard-right-margin state))
               (not (write-for-read state)))
          (pprogn
           (princ$ #\\ channel state)
           (newline channel state)
           (fmt-tilde-s1 s i maximum 0 channel state)))
         (t
          (let ((c (charf s i))
                (fmt-soft-right-margin (fmt-soft-right-margin state)))
            (declare (type character c)
                     (type (signed-byte 30) fmt-soft-right-margin))
            (cond ((and (> col fmt-soft-right-margin)
                        (not (write-for-read state))
                        (eql c #\Space))
                   (pprogn
                    (newline channel state)
                    (fmt-tilde-s1 s
                                  (scan-past-whitespace s (+f i 1) maximum)
                                  maximum 0 channel state)))
                  ((and (> col fmt-soft-right-margin)
                        (not (write-for-read state))
                        (or (eql c #\-)
                            (eql c #\_))
                        (not (int= (1+f i) maximum)))

; If we are beyond the soft right margin and we are about to print a
; hyphen or underscore and it is not the last character in the string,
; then print it and do a terpri.  If it is the last character, as it
; is in say, the function name "1-", then we don't do the terpri and
; hope there is a better place to break soon.  The motivating example
; for this was in seeing a list of function names get printed in a way
; that produced a comma as the first character of the newline, e.g.,
; "... EQL, 1+, 1-
; , ZEROP and PLUSP."

                   (pprogn
                    (princ$ c channel state)
                    (if (eql c #\-) state (princ$ #\- channel state))
                    (newline channel state)
                    (fmt-tilde-s1 s
                                  (scan-past-whitespace s (+f i 1) maximum)
                                  maximum 0 channel state)))
                  (t
                   (pprogn
                    (princ$ c channel state)
                    (fmt-tilde-s1 s (1+f i) maximum (1+f col)
                                  channel state)))))))))

(defun fmt-var (s alist i maximum)
  (declare (type (signed-byte 30) i maximum)
           (type string s))
  (let ((x (assoc (the character (fmt-char s i 2 maximum t)) alist)))
    (cond (x (cdr x))
          (t (er hard 'fmt-var
                 "Unbound Fmt Variable.  The tilde directive at location ~x0 ~
                  in the fmt string below uses the variable ~x1.  But ~
                  this variable is not bound in the association list, ~
                  ~x2, supplied with the fmt string.~|~%~x3"
                 i (char s (+f i 2)) alist s)))))

(defun splat-atom (x print-base print-radix indent col channel state)
  (let* ((sz (flsz-atom x print-base print-radix 0 state))
         (too-bigp (> (+ col sz) (fmt-hard-right-margin state))))
    (pprogn (if too-bigp
                (pprogn (newline channel state)
                        (spaces indent 0 channel state))
                state)
            (prin1$ x channel state)
            (mv (if too-bigp (+ indent sz) (+ col sz))
                state))))

; Splat, below, prints out an arbitrary ACL2 object flat, introducing
; the single-gritch notation for quote and breaking lines between lexemes
; to avoid going over the hard right margin.  It indents all but the first
; line by indent spaces.

(mutual-recursion

(defun splat (x print-base print-radix indent col channel state)
  (cond ((atom x)
         (splat-atom x print-base print-radix indent col channel state))
        ((and (eq (car x) 'quote)
              (consp (cdr x))
              (null (cddr x)))
         (pprogn (princ$ #\' channel state)
                 (splat (cadr x) print-base print-radix indent (1+ col) channel
                        state)))
        (t (pprogn (princ$ #\( channel state)
                   (splat1 x print-base print-radix indent (1+ col) channel
                           state)))))

(defun splat1 (x print-base print-radix indent col channel state)
  (mv-let (col state)
          (splat (car x) print-base print-radix indent col channel state)
          (cond ((null (cdr x))
                 (pprogn (princ$ #\) channel state)
                         (mv (1+ col) state)))
                ((atom (cdr x))
                 (cond ((> (+ 3 col) (fmt-hard-right-margin state))
                        (pprogn (newline channel state)
                                (spaces indent 0 channel state)
                                (princ$ ". " channel state)
                                (mv-let (col state)
                                        (splat (cdr x)
                                               print-base print-radix indent
                                               (+ indent 2)
                                               channel state)
                                        (pprogn (princ$ #\) channel state)
                                                (mv (1+ col) state)))))
                       (t (pprogn
                           (princ$ " . " channel state)
                           (mv-let (col state)
                                   (splat (cdr x)
                                          print-base print-radix indent
                                          (+ 3 col)
                                          channel state)
                                   (pprogn (princ$ #\) channel state)
                                           (mv (1+ col) state)))))))
                (t (pprogn
                    (princ$ #\Space channel state)
                    (splat1 (cdr x) print-base print-radix indent (1+ col)
                            channel state))))))

)

(defun number-of-digits (n print-base print-radix)

; We compute the width of the field necessary to express the integer n
; in the given print-base.  We assume minus signs are printed but plus
; signs are not.  Thus, if n is -123 we return 4, if n is 123 we
; return 3.

  (cond ((< n 0) (1+ (number-of-digits (abs n) print-base print-radix)))
        ((< n print-base)
         (cond ((null print-radix)
                1)
               ((int= print-base 10) ; `.' suffix
                2)
               (t ; #b, #o, or #x prefix
                3)))
        (t (1+ (number-of-digits (floor n print-base) print-base
                                 print-radix)))))

(defun left-pad-with-blanks (n width col channel state)

; Print the integer n right-justified in a field of width width.
; We return the final column (assuming we started in col) and state.

  (declare (type (signed-byte 30) col))
  (the2s
   (signed-byte 30)
   (let ((d (the-half-fixnum! (number-of-digits n (print-base) (print-radix))
                              'left-pad-with-blanks)))
     (declare (type (signed-byte 30) d))
     (cond ((>= d width)
            (pprogn (prin1$ n channel state)
                    (mv (+ col d) state)))
           (t (pprogn
               (spaces (- width d) col channel state)
               (prin1$ n channel state)
               (mv (the-fixnum! (+ col width) 'left-pad-with-blanks)
                   state)))))))

(defmacro maybe-newline (body)

; This macro is used in fmt0 to force a newline only when absolutely
; necessary.  It knows the locals of fmt0, in particular, col,
; channel, and state.  We wrap this macro around code that is about to
; print a character at col.  Once upon a time we just started fmt0
; with a newline if we were past the hard right margin, but that
; produced occasional lines that ended naturally at the hard right
; margin and then had a backslash inserted in anticipation of the 0
; characters to follow.  It was impossible to tell if more characters
; follow because there may be tilde commands between where you are and
; the end of the line, and they may or may not print things.

  `(mv-letc (col state)
            (cond
             ((and (> col (fmt-hard-right-margin state))
                   (not (write-for-read state)))
              (pprogn (princ$ #\\ channel state)
                      (newline channel state)
                      (mv 0 state)))
             (t (mv col state)))
            ,body))

; To support the convention that er, fmt, and even individual fmt
; commands such as ~X can control their own evisceration parameters,
; we now introduce the idea of an evisceration tuple, or evisc-tuple.

(defun evisc-tuple (print-level print-length alist hiding-cars)

; See :doc set-evisc-tuple for a lot of information about evisc-tuples.  Also
; see the Essay on Iprinting for a related topic.

; This is really just a record constructor, but we haven't got defrec
; yet so we do it by hand.  See set-evisc-tuple.

; We sometimes write out constant evisc tuples!  However they are commented
; nearby with (evisc-tuple ...).

; The primitive consumers of evisc tuples all call eviscerate-top or
; eviscerate-stobjs-top.

;         car   cadr        caddr        cadddr

  (list alist   print-level print-length hiding-cars))

(defun standard-evisc-tuplep (x)
  (or (null x)
      (and (true-listp x)
           (= (length x) 4)
           (alistp (car x))
           (or (null (cadr x))
               (integerp (cadr x)))
           (or (null (caddr x))
               (integerp (caddr x)))
           (symbol-listp (cadddr x)))))

(defun abbrev-evisc-tuple (state)

; As of January 2009 the abbrev-evisc-tuple is used in error, warning$,
; observation, pstack, break-on-error, and miscellany such as running commands
; where little output is desired, say for :ubt or rebuild.  We don't put this
; complete of a specification into the documentation, however, in case later we
; tweak the set of uses of the abbrev-evisc-tuple.  This comment should
; similarly not be viewed as definitive if it is long after January 2009.

  (let ((evisc-tuple (f-get-global 'abbrev-evisc-tuple state)))
    (cond
     ((eq evisc-tuple :default)
      (cons (world-evisceration-alist state nil)
            '(5 7 nil)))
     (t evisc-tuple))))

(defmacro gag-mode ()
  '(f-get-global 'gag-mode state))

(defun term-evisc-tuple (flg state)

; This evisceration tuple is used when we are printing terms or lists of terms.
; If state global 'term-evisc-tuple has value other than :default, then we
; return that value.  Otherwise:

; We don't hide the world or state because they aren't (usually) found in
; terms.  This saves us a little time.  If the global value of
; 'eviscerate-hide-terms is t, we print (HIDE ...) as <hidden>.  Otherwise not.
; Flg controls whether we actually eviscerate on the basis of structural depth
; and length.  If flg is t we do.  The choice of the print-length 4 is
; motivated by the idea of being able to print IF as (IF # # #) rather than (IF
; # # ...).  Print-level 3 lets us print a clause as ((NOT (PRIMEP #)) ...)
; rather than ((NOT #) ...).

  (let ((evisc-tuple (f-get-global 'term-evisc-tuple state)))
    (cond ((not (eq evisc-tuple :default))
           evisc-tuple)
          ((f-get-global 'eviscerate-hide-terms state)
           (cond (flg
;;; (evisc-tuple 3 4 nil '(hide))
                  '(nil 3 4 (hide)))
                 (t
;;; (evisc-tuple nil nil nil '(hide))
                  '(nil nil nil (hide)))))
          (flg ;;; (evisc-tuple 3 4 nil nil)
           '(nil 3 4 nil))
          (t nil))))

(defun gag-mode-evisc-tuple (state)
  (cond ((gag-mode)
         (let ((val (f-get-global 'gag-mode-evisc-tuple state)))
           (if (eq val :DEFAULT)
               nil
             val)))
        (t (term-evisc-tuple nil state))))

(defun ld-evisc-tuple (state)
  (let ((evisc-tuple (f-get-global 'ld-evisc-tuple state)))
    (assert$ (not (eq evisc-tuple :default)) ; only abbrev, term evisc-tuples
             evisc-tuple)))

#-acl2-loop-only
(defun-one-output print-infix (x termp width rpc col file eviscp)

; X is an s-expression denoting a term (if termp = t) or an evg (if
; termp = nil).  File is an open output file.  Prettyprint x in infix
; notation to file.  If eviscp is t then we are to give special treatment to
; the :evisceration-mark; otherwise not.

; This hook is modeled after the ACL2 pretty-printer, which has the following
; additional features.  These features need not be implemented in the infix
; prettyprinter.  The printer is assumed to be in column col, where col=0 means
; it is on the left margin.  We are supposed to print our first character in
; that column.  We are supposed to print in a field of width width.  That is,
; the largest column into which we might print is col+width-2.  Finally, assume
; that on the last line of the output somebody is going to write rpc additional
; characters and arrange for this not to overflow the col+width-2 limit.  Rpc
; is used when, for example, we plan to print some punctuation, like a comma,
; after a form and want to ensure that we can do it without overflowing the
; right margin.  (One might think that the desired effect could be obtained by
; setting width smaller, but that is wrong because it narrows the whole field
; and we only want to guarantee space on the last line.)  Here is an example.
; Use ctrl-x = in emacs to see what columns things are in.  The semi-colons are
; in column 0.  Pretend they are all spaces, as they would be if the printing
; had been done by fmt-ppr.

; (foobar
;   (here is a long arg)
;   a)

; Here, col = 2, width = 23, and rpc = 19!

; Infix Hack:
; We simply print out $ followed by the expression.  We print the
; expression in lower-case.

  (declare (ignore termp width rpc col eviscp))
  (let ((*print-case* :downcase)
        (*print-pretty* t))
    (princ "$ " file)
    (prin1 x file)))

(defun fmt-ppr (x termp width rpc col channel state eviscp)
  (declare (type (signed-byte 30) col))
  #+acl2-loop-only
  (declare (ignore termp))
  #-acl2-loop-only
  (cond
   ((and (live-state-p state)
         (output-in-infixp state))
    (print-infix x termp width rpc col
                 (get-output-stream-from-channel channel)
                 eviscp)
    (return-from fmt-ppr *the-live-state*)))
  (ppr2 (ppr1 x (print-base) (print-radix) width rpc state eviscp)
        col channel state eviscp))

(mutual-recursion

(defun fmt0* (str0 str1 str2 str3 lst alist col channel state evisc-tuple)

; This odd function prints out the members of lst.  If the list has no
; elements, str0 is used.  If the list has 1 element, str1 is used
; with #\* bound to the element.  If the list has two elements, str2
; is used with #\* bound to the first element and then str1 is used
; with #\* bound to the second.  If the list has more than two
; elements, str3 is used with #\* bound successively to each element
; until there are only two left.  The function is used in the
; implementation of ~&, ~v, and ~*.

  (declare (type (signed-byte 30) col)
           (type string str0 str1 str2 str3))
  (the2s
   (signed-byte 30)
   (cond ((null lst)
          (fmt0 str0 alist 0 (the-fixnum! (length str0) 'fmt0*) col channel
                state evisc-tuple))
         ((null (cdr lst))
          (fmt0 str1
                (cons (cons #\* (car lst)) alist)
                0 (the-fixnum! (length str1) 'fmt0*) col channel
                state evisc-tuple))
         ((null (cddr lst))
          (mv-letc (col state)
                   (fmt0 str2
                         (cons (cons #\* (car lst)) alist)
                         0 (the-fixnum! (length str2) 'fmt0*)
                         col channel state evisc-tuple)
                   (fmt0* str0 str1 str2 str3 (cdr lst) alist col channel
                          state evisc-tuple)))
         (t (mv-letc (col state)
                     (fmt0 str3
                           (cons (cons #\* (car lst)) alist)
                           0 (the-fixnum! (length str3) 'fmt0*)
                           col channel state evisc-tuple)
                     (fmt0* str0 str1 str2 str3 (cdr lst) alist col channel
                            state evisc-tuple))))))

(defun fmt0&v (flg lst punct col channel state evisc-tuple)
  (declare (type (signed-byte 30) col))
  (the2s
   (signed-byte 30)
   (case flg
     (&
      (case
          punct
        (#\. (fmt0* "" "~x*." "~x* and " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\, (fmt0* "" "~x*," "~x* and " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\: (fmt0* "" "~x*:" "~x* and " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\; (fmt0* "" "~x*;" "~x* and " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\! (fmt0* "" "~x*!" "~x* and " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\) (fmt0* "" "~x*)" "~x* and " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\? (fmt0* "" "~x*?" "~x* and " "~x*, " lst nil col channel
                    state evisc-tuple))
        (otherwise
         (fmt0* "" "~x*" "~x* and " "~x*, " lst nil col channel
                state evisc-tuple))))
     (otherwise
      (case
          punct
        (#\. (fmt0* "" "~x*." "~x* or " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\, (fmt0* "" "~x*," "~x* or " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\: (fmt0* "" "~x*:" "~x* or " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\; (fmt0* "" "~x*;" "~x* or " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\! (fmt0* "" "~x*!" "~x* or " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\) (fmt0* "" "~x*)" "~x* or " "~x*, " lst nil col channel
                    state evisc-tuple))
        (#\? (fmt0* "" "~x*?" "~x* or " "~x*, " lst nil col channel
                    state evisc-tuple))
        (otherwise
         (fmt0* "" "~x*" "~x* or " "~x*, " lst nil col channel
                state evisc-tuple)))))))

(defun spell-number (n cap col channel state evisc-tuple)

; If n is an integerp we spell out the name of the cardinal number n
; (for a few cases) or else we just print the decimal representation
; of n.  E.g., n=4 makes us spell "four".  If n is a consp then we
; assume its car is an integer and we spell the corresponding ordinal
; number, e.g., n= '(4 . th) makes us spell "fourth".  We capitalize
; the word if cap is t.

  (declare (type (signed-byte 30) col))
  (the2s
   (signed-byte 30)
   (let ((str
          (cond ((integerp n)
                 (cond ((int= n 0) (if cap "Zero" "zero"))
                       ((int= n 1) (if cap "One" "one"))
                       ((int= n 2) (if cap "Two" "two"))
                       ((int= n 3) (if cap "Three" "three"))
                       ((int= n 4) (if cap "Four" "four"))
                       ((int= n 5) (if cap "Five" "five"))
                       ((int= n 6) (if cap "Six" "six"))
                       ((int= n 7) (if cap "Seven" "seven"))
                       ((int= n 8) (if cap "Eight" "eight"))
                       ((int= n 9) (if cap "Nine" "nine"))
                       ((int= n 10) (if cap "Ten" "ten"))
                       ((int= n 11) (if cap "Eleven" "eleven"))
                       ((int= n 12) (if cap "Twelve" "twelve"))
                       ((int= n 13) (if cap "Thirteen" "thirteen"))
                       (t "~x0")))
                ((and (consp n)
                      (<= 0 (car n))
                      (<= (car n) 13))
                 (cond ((int= (car n) 0) (if cap "Zeroth" "zeroth"))
                       ((int= (car n) 1) (if cap "First" "first"))
                       ((int= (car n) 2) (if cap "Second" "second"))
                       ((int= (car n) 3) (if cap "Third" "third"))
                       ((int= (car n) 4) (if cap "Fourth" "fourth"))
                       ((int= (car n) 5) (if cap "Fifth" "fifth"))
                       ((int= (car n) 6) (if cap "Sixth" "sixth"))
                       ((int= (car n) 7) (if cap "Seventh" "seventh"))
                       ((int= (car n) 8) (if cap "Eighth" "eighth"))
                       ((int= (car n) 9) (if cap "Ninth" "ninth"))
                       ((int= (car n) 10) (if cap "Tenth" "tenth"))
                       ((int= (car n) 11) (if cap "Eleventh" "eleventh"))
                       ((int= (car n) 12) (if cap "Twelfth" "twelfth"))
                       (t (if cap "Thirteenth" "thirteenth"))))
                (t (let ((d (mod (abs (car n)) 10)))

; We print -11th, -12th, -13th, ... -20th, -21st, -22nd, etc., though
; what business anyone has using negative ordinals I can't imagine.

                     (cond ((or (int= d 0)
                                (> d 3)
                                (int= (car n) -11)
                                (int= (car n) -12)
                                (int= (car n) -13))
                            "~x0th")
                           ((int= d 1) "~x0st")
                           ((int= d 2) "~x0nd")
                           (t "~x0rd")))))))

     (fmt0 (the-string! str 'spell-number)
           (cond ((integerp n)
                  (cond ((and (<= 0 n) (<= n 13)) nil)
                        (t (list (cons #\0 n)))))
                 (t (cond ((and (<= 0 (car n)) (<= (car n) 13)) nil)
                          (t (list (cons #\0 (car n)))))))
           0 (the-fixnum! (length str) 'spell-number)
           col channel state evisc-tuple))))

(defun fmt-tilde-s (s col channel state)

; If s is a symbol or a string, we print it out, breaking on hyphens but not
; being fooled by fmt directives inside it.  We also allow s to be a number
; (not sure why this was ever allowed, but we continue to support it).  We
; return the new col and state.

  (declare (type (signed-byte 30) col))
  (the2s
   (signed-byte 30)
   (cond
    ((acl2-numberp s)
     (pprogn (prin1$ s channel state)
             (mv (flsz-atom s (print-base) (print-radix) col state) state)))
    ((stringp s)
     (fmt-tilde-s1 s 0 (the-fixnum! (length s) 'fmt-tilde-s) col
                   channel state))
    (t
     (let ((str (symbol-name s)))
       (cond
        ((keywordp s)
         (cond
          ((needs-slashes str state)
           (splat-atom s (print-base) (print-radix) 0 col channel state))
          (t (fmt0 ":~s0" (list (cons #\0 str)) 0 4 col channel state nil))))
        ((symbol-in-current-package-p s state)
         (cond
          ((needs-slashes str state)
           (splat-atom s (print-base) (print-radix) 0 col channel state))
          (t (fmt-tilde-s1 str 0
                           (the-fixnum! (length str) 'fmt-tilde-s)
                           col channel state))))
        (t
         (let ((p (symbol-package-name s)))
           (cond
            ((or (needs-slashes p state)
                 (needs-slashes str state))
             (splat-atom s (print-base) (print-radix) 0 col channel state))
            (t (fmt0 "~s0::~-~s1"
                     (list (cons #\0 p)
                           (cons #\1 str))
                     0 10 col channel state nil)))))))))))

(defun fmt0 (s alist i maximum col channel state evisc-tuple)
  (declare (type (signed-byte 30) i maximum col)
           (type string s))

; WARNING:  If you add new tilde-directives update :DOC fmt and the
; copies in :DOC fmt1 and :DOC fms.

  (declare (type (signed-byte 30) col))
  (the2s
   (signed-byte 30)
   (cond
    ((>= i maximum)
     (mv (the (signed-byte 30) col) state))
    (t
     (let ((c (charf s i)))
       (declare (type character c))
       (cond
        ((eql c #\~)
         (let ((fmc (the character (fmt-char s i 1 maximum t))))
           (declare (type character fmc))
           (case
            fmc
             ((#\p #\q #\P #\Q #\x #\y #\X #\Y)

; The only difference between pqPQ and xyXY is that the former can cause infix
; printing.  (But see the comment below about "hyphenate" for how we can cause
; the latter to enable hyphenation.)  However, as of this writing (Jan. 2009)
; it is far from clear that infix printing still works; so we consider it to be
; deprecated.  Infix printing assumes the term has already been untranslated.

; The difference between the lowercase directives and the uppercase ones is
; that the uppercase ones take two fmt-vars, e.g., ~X01, and use the contents
; of the second one as the evisceration value.  Otherwise the uppercase
; directives behave as their lowercase counterparts.

; On symbols, ~x and ~y are alike and just print starting in col.  On non-
; symbols they both prettyprint.  But ~y starts printing in col while ~x may do
; a terpri and indent first.  ~x concludes with a terpri if it put out a terpri
; before printing.  ~y always concludes with a terpri on non-symbols, so you
; know where you end up.

              (maybe-newline
               (let* ((caps (or (eql fmc #\P) (eql fmc #\Q)
                                (eql fmc #\X) (eql fmc #\Y)))
                      (px (or (eql fmc #\p) (eql fmc #\P)
                              (eql fmc #\x) (eql fmc #\X)))
                      (qy (not px))
                      (pq (or (eql fmc #\p) (eql fmc #\P)
                              (eql fmc #\q) (eql fmc #\Q)))
                      (local-evisc-tuple
                       (cond (caps
                              (fmt-var s alist (1+f i) maximum))
                             (t evisc-tuple)))
                      (evisc-table (table-alist 'evisc-table (w state)))
                      (eviscp (or local-evisc-tuple evisc-table)))
                 (mv-let
                  (x state)
                  (cond (eviscp (eviscerate-top
                                 (fmt-var s alist i maximum)
                                 (cadr local-evisc-tuple)   ;;; print-level
                                 (caddr local-evisc-tuple)  ;;; print-length
                                 (car local-evisc-tuple)    ;;; alist
                                 evisc-table
                                 (cadddr local-evisc-tuple) ;;; hiding-cars
                                 state))
                        (t (mv (fmt-var s alist i maximum)
                               state)))

; Through Version_3.4, ACL2 could hyphenate rule names during proof commentary
; because of the following COND branch in the case of ~x/~y/~X/~Y (though
; fmt-symbol-name has since been renamed as fmt-tilde-s).  We have decided to
; opt instead for uniform treatment of ~x/~y/~X/~Y and ~p/~q/~P/~Q, modulo
; potential support for infix printing for the latter group (which we may
; eliminate in the future).  By avoiding hyphenation we make it easier for a
; user to grab a rule name from the output, though now one might want to do
; some hyphenation by hand when preparing proof output for publication.

;                   ((and (or (symbolp x)
;                             (acl2-numberp x))
;                         (member-eq fmc '(#\x #\y #\X #\Y)))
;                    (mv-letc (col state)
;                             (fmt-tilde-s x col channel state)
;                             (fmt0 s alist
;                                   (+f i (if (or (eql fmc #\X)
;                                                 (eql fmc #\Y))
;                                             4
;                                           3))
;                                   maximum col channel state evisc-tuple)))

                  (let ((fmt-hard-right-margin
                         (fmt-hard-right-margin state)))
                    (declare (type (signed-byte 30) fmt-hard-right-margin))
                    (let ((sz (flsz x pq col fmt-hard-right-margin state
                                    eviscp)))
                      (declare (type (signed-byte 30) sz))
                      (cond
                       ((and px
                             (> col (the-fixnum *fmt-ppr-indentation*))
                             (>= sz fmt-hard-right-margin)
                             (not (>= (flsz x
                                            pq
                                            (the-fixnum
                                             *fmt-ppr-indentation*)
                                            fmt-hard-right-margin
                                            state eviscp)
                                      fmt-hard-right-margin)))
                        (pprogn
                         (newline channel state)
                         (spaces1 (the-fixnum *fmt-ppr-indentation*) 0
                                  fmt-hard-right-margin
                                  channel state)
                         (fmt0 s alist i maximum
                               (the-fixnum *fmt-ppr-indentation*)
                               channel state evisc-tuple)))
                       ((or qy
                            (>= sz fmt-hard-right-margin))
                        (pprogn
                         (cond (qy
                                state)
                               ((= col 0) state)
                               (t (newline channel state)))
                         (if qy
                             state
                           (spaces1 (the-fixnum *fmt-ppr-indentation*)
                                    0 fmt-hard-right-margin channel state))
                         (let ((c (fmt-char s i
                                            (the-fixnum
                                             (if caps
                                                 4
                                               3))
                                            maximum nil)))
                           (cond ((punctp c)
                                  (pprogn
                                   (fmt-ppr
                                    x
                                    pq
                                    (+f fmt-hard-right-margin
                                        (-f (if qy
                                                col
                                              *fmt-ppr-indentation*)))
                                    1
                                    (the-fixnum
                                     (if qy
                                         col
                                       *fmt-ppr-indentation*))
                                    channel state eviscp)
                                   (princ$ c channel state)
                                   (newline channel state)
                                   (fmt0 s alist
                                         (scan-past-whitespace
                                          s
                                          (+f i (if caps
                                                    5
                                                  4))
                                          maximum)
                                         maximum 0 channel state
                                         evisc-tuple)))
                                 (t
                                  (pprogn
                                   (fmt-ppr
                                    x
                                    pq
                                    (+f fmt-hard-right-margin
                                        (-f (if qy
                                                col
                                              *fmt-ppr-indentation*)))
                                    0
                                    (the-fixnum
                                     (if qy
                                         col
                                       *fmt-ppr-indentation*))
                                    channel state eviscp)
                                   (newline channel state)
                                   (fmt0 s alist
                                         (scan-past-whitespace
                                          s
                                          (+f i (if caps
                                                    4
                                                  3))
                                          maximum)
                                         maximum 0 channel state
                                         evisc-tuple)))))))
                       (t (pprogn
                           (flpr x pq channel state eviscp)
                           (fmt0 s alist
                                 (+f i (if caps
                                           4
                                         3))
                                 maximum sz
                                 channel state evisc-tuple))))))))))
             (#\@ (let ((s1 (fmt-var s alist i maximum)))
                    (mv-letc (col state)
                             (cond ((stringp s1)
                                    (fmt0 s1 alist 0
                                          (the-fixnum! (length s1) 'fmt0)
                                          col channel state evisc-tuple))
                                   ((consp s1)
                                    (fmt0 (car s1)
                                          (append (cdr s1) alist)
                                          0
                                          (the-fixnum! (length (car s1)) 'fmt0)
                                          col channel state evisc-tuple))
                                   (t (mv (er-hard-val 0 'fmt0
                                              "Illegal Fmt Syntax.  The ~
                                               tilde-@ directive at position ~
                                               ~x0 of the string below is ~
                                               illegal because its variable ~
                                               evaluated to ~x1, which is ~
                                               neither a string nor a ~
                                               list.~|~%~x2"
                                              i s1 s)
                                          state)))
                             (fmt0 s alist (+f i 3) maximum col
                                   channel state evisc-tuple))))
             (#\# (let ((n (find-alternative-start
                            (fmt-var s alist i maximum) s i maximum)))
                    (declare (type (signed-byte 30) n))
                    (let ((m (find-alternative-stop s n maximum)))
                      (declare (type (signed-byte 30) m))
                      (let ((o (find-alternative-skip s m maximum)))
                        (declare (type (signed-byte 30) o))
                        (mv-letc (col state) (fmt0 s alist
                                                   (the-fixnum n)
                                                   (the-fixnum m)
                                                   col channel
                                                   state evisc-tuple)
                                 (fmt0 s alist (the-fixnum o) maximum
                                       col channel state evisc-tuple))))))
             (#\* (let ((x (fmt-var s alist i maximum)))
                    (mv-letc (col state)
                             (fmt0* (car x) (cadr x) (caddr x) (cadddr x)
                                    (car (cddddr x))
                                    (append (cdr (cddddr x)) alist)
                                    col channel state evisc-tuple)
                             (fmt0 s alist (+f i 3) maximum col
                                   channel state evisc-tuple))))
             (#\& (let ((i+3 (+f i 3)))
                    (declare (type (signed-byte 30) i+3))
                    (mv-letc (col state)
                             (fmt0&v '&
                                     (fmt-var s alist i maximum)
                                     (punctp (and (< i+3 maximum)
                                                  (char s i+3)))
                                     col channel state evisc-tuple)
                             (fmt0 s alist
                                   (the-fixnum
                                    (cond
                                     ((punctp (and (< i+3 maximum)
                                                   (char s i+3)))
                                      (+f i 4))
                                     (t i+3)))
                                   maximum
                                   col channel state evisc-tuple))))
             (#\v (let ((i+3 (+f i 3)))
                    (declare (type (signed-byte 30) i+3))
                    (mv-letc (col state)
                             (fmt0&v 'v
                                     (fmt-var s alist i maximum)
                                     (punctp (and (< i+3 maximum)
                                                  (char s i+3)))
                                     col channel state evisc-tuple)
                             (fmt0 s alist
                                   (the-fixnum
                                    (cond
                                     ((punctp (and (< i+3 maximum)
                                                   (char s i+3)))
                                      (+f i 4))
                                     (t i+3)))
                                   maximum
                                   col channel state evisc-tuple))))
             (#\n (maybe-newline
                   (mv-letc (col state)
                            (spell-number (fmt-var s alist i maximum)
                                          nil col channel state evisc-tuple)
                            (fmt0 s alist (+f i 3) maximum col channel
                                  state evisc-tuple))))
             (#\N (maybe-newline
                   (mv-letc (col state)
                            (spell-number (fmt-var s alist i maximum)
                                          t col channel state evisc-tuple)
                            (fmt0 s alist (+f i 3) maximum col channel
                                  state evisc-tuple))))
             (#\t (maybe-newline
                   (let ((goal-col (fmt-var s alist i maximum))
                         (fmt-hard-right-margin (fmt-hard-right-margin state)))
                     (declare (type (signed-byte 30)
                                    goal-col fmt-hard-right-margin))
                     (pprogn
                      (cond ((> goal-col fmt-hard-right-margin)
                             (let ((er (er hard 'fmt0
                                           "It is illegal to tab past the ~
                                            value of (@ ~
                                            fmt-hard-right-margin), ~x0, and ~
                                            hence the directive ~~t~s1 to tab ~
                                            to column ~x2 is illegal.  See ~
                                            :DOC set-fmt-hard-right-margin."
                                           fmt-hard-right-margin
                                           (string (fmt-char s i 2 maximum t))
                                           goal-col)))
                               (declare (ignore er))
                               state))
                            ((>= col goal-col)
                             (pprogn (newline channel state)
                                     (spaces1 (the-fixnum goal-col) 0
                                              fmt-hard-right-margin
                                              channel state)))
                            (t (spaces1 (-f goal-col col) col
                                        fmt-hard-right-margin
                                        channel state)))
                      (fmt0 s alist (+f i 3) maximum
                            (the-fixnum goal-col)
                            channel state evisc-tuple)))))
             (#\c (maybe-newline
                   (let ((pair (fmt-var s alist i maximum)))
                     (cond ((and (consp pair)
                                 (integerp (car pair))
                                 (integerp (cdr pair))
                                 (>= (cdr pair) 0))
                            (mv-letc (col state)
                                     (left-pad-with-blanks (car pair)
                                                           (cdr pair)
                                                           col channel state)
                                     (fmt0 s alist (+f i 3) maximum col channel
                                           state evisc-tuple)))
                           (t (mv (er-hard-val 0 'fmt0
                                      "Illegal Fmt Syntax.  The tilde-c ~
                                       directive at position ~x0 of the string ~
                                       below is illegal because its variable ~
                                       evaluated to ~x1, which is not of the ~
                                       form (n . width), where n and width are ~
                                       integers and width is ~
                                       nonnegative.~|~%~x2"
                                      i pair s)
                                  state))))))
             ((#\f #\F)
              (maybe-newline
               (mv-letc (col state)
                        (splat (fmt-var s alist i maximum)
                               (print-base) (print-radix)
                               (if (eql fmc #\F) (1+f col) 0)
                               col channel state)
                        (fmt0 s alist (+f i 3) maximum col channel
                              state evisc-tuple))))
             (#\s (maybe-newline
                   (mv-letc (col state)
                            (fmt-tilde-s (fmt-var s alist i maximum) col
                                         channel state)
                            (fmt0 s alist (+f i 3) maximum col channel
                                  state evisc-tuple))))
             (#\Space (let ((fmt-hard-right-margin
                             (fmt-hard-right-margin state)))
                        (declare (type (signed-byte 30) fmt-hard-right-margin))
                        (pprogn
                         (cond ((> col fmt-hard-right-margin)
                                (newline channel state))
                               (t state))
                         (princ$ #\Space channel state)
                         (fmt0 s alist (+f i 2) maximum
                               (cond ((> col fmt-hard-right-margin)
                                      1)
                                     (t (1+f col)))
                               channel state evisc-tuple))))
             (#\_ (maybe-newline
                   (let ((fmt-hard-right-margin
                          (fmt-hard-right-margin state)))
                     (declare (type (signed-byte 30) fmt-hard-right-margin))
                     (let ((n (the-half-fixnum! (fmt-var s alist i maximum)
                                                'fmt0)))
                       (declare (type (signed-byte 30) n))
                       (let ((new-col (+f col n)))
                         (declare (type (signed-byte 30) new-col))
                         (pprogn
                          (spaces n col channel state)
                          (cond
                           ((> new-col fmt-hard-right-margin)
                            (newline channel state))
                           (t state))
                          (fmt0 s alist (+f i 3) maximum
                                (the-fixnum
                                 (cond
                                  ((> new-col fmt-hard-right-margin)
                                   0)
                                  (t new-col)))
                                channel state evisc-tuple)))))))
             (#\Newline
              (fmt0 s alist (scan-past-whitespace s (+f i 2) maximum)
                    maximum col channel state evisc-tuple))
             (#\| (pprogn
                   (if (int= col 0) state (newline channel state))
                   (fmt0 s alist (+f i 2)
                         maximum 0 channel state evisc-tuple)))
             (#\% (pprogn
                   (newline channel state)
                   (fmt0 s alist (+f i 2)
                         maximum 0 channel state evisc-tuple)))
             (#\~ (maybe-newline
                   (pprogn
                    (princ$ #\~ channel state)
                    (fmt0 s alist (+f i 2) maximum (1+f col) channel
                          state evisc-tuple))))
             (#\- (cond ((> col (fmt-soft-right-margin state))
                         (pprogn
                          (princ$ #\- channel state)
                          (newline channel state)
                          (fmt0 s alist
                                (scan-past-whitespace s (+f i 2) maximum)
                                maximum 0 channel state evisc-tuple)))
                        (t (fmt0 s alist (+f i 2) maximum col channel
                                 state evisc-tuple))))
             (otherwise (let ((x
                               (er hard 'fmt0
                                   "Illegal Fmt Syntax.  The tilde ~
                                     directive at position ~x0 of the ~
                                     string below is unrecognized.~|~%~x1"
                                   i s)))
                          (declare (ignore x))
                          (mv 0 state))))))
        ((and (> col (fmt-soft-right-margin state))
              (eql c #\Space))
         (pprogn (newline channel state)
                 (fmt0 s alist
                       (scan-past-whitespace s (+f i 1) maximum)
                       maximum
                       0 channel state evisc-tuple)))
        ((and (>= col (fmt-soft-right-margin state))
              (eql c #\-))
         (pprogn (princ$ c channel state)
                 (newline channel state)
                 (fmt0 s alist
                       (scan-past-whitespace s (+f i 1) maximum)
                       maximum
                       0 channel state evisc-tuple)))
;       ((and (eql c #\Space)
; I cut out this code in response to Kaufmann's complaint 38.  The idea is
; *not* to ignore spaces after ~% directives.  I've left the code here to
; remind me of what I used to do, in case I see output that is malformed.
;            (int= col 0))
;       (fmt0 s alist (+f i 1) maximum 0 channel state evisc-tuple))
        (t (maybe-newline
            (pprogn (princ$ c channel state)
                    (fmt0 s alist (+f i 1) maximum
                          (if (eql c #\Newline) 0 (+f col 1))
                          channel state evisc-tuple))))))))))

)

(defun tilde-*-&v-strings (flg lst punct)

; This function returns an object that when bound to #\0 will cause
; ~*0 to print a conjunction (flg='&) or disjunction (flg='v) of the
; strings in lst, followed by punctuation punct, which must be #\. or
; #\,.

; WARNING:  This displayed strings are not equal to the strings in lst
; because whitespace may be inserted!

; ~& doesn't print a list of short strings very well because the first
; group is printed flat across the line, then when the line gets too
; long, the next string is indented and followed by a newline, which
; allows another bunch to be printed flat.  This function prints them
; with ~s which actually breaks the strings up internally in a way
; that does not preserve their equality.  "history-management.lisp"
; might have a newline inserted after the hyphen.

  (case
   flg
   (&
    (case
     punct
     (#\. (list "" "\"~s*\"." "\"~s*\" and " "\"~s*\", " lst))
     (#\, (list "" "\"~s*\"," "\"~s*\" and " "\"~s*\", " lst))
     (#\: (list "" "\"~s*\":" "\"~s*\" and " "\"~s*\", " lst))
     (#\; (list "" "\"~s*\";" "\"~s*\" and " "\"~s*\", " lst))
     (#\! (list "" "\"~s*\"!" "\"~s*\" and " "\"~s*\", " lst))
     (#\) (list "" "\"~s*\")" "\"~s*\" and " "\"~s*\", " lst))
     (#\? (list "" "\"~s*\"?" "\"~s*\" and " "\"~s*\", " lst))
     (otherwise
      (list "" "\"~s*\"" "\"~s*\" and " "\"~s*\", " lst))))
   (otherwise
    (case
     punct
     (#\. (list "" "\"~s*\"." "\"~s*\" or " "\"~s*\", " lst))
     (#\, (list "" "\"~s*\"," "\"~s*\" or " "\"~s*\", " lst))
     (#\: (list "" "\"~s*\":" "\"~s*\" or " "\"~s*\", " lst))
     (#\; (list "" "\"~s*\";" "\"~s*\" or " "\"~s*\", " lst))
     (#\! (list "" "\"~s*\"!" "\"~s*\" or " "\"~s*\", " lst))
     (#\) (list "" "\"~s*\")" "\"~s*\" or " "\"~s*\", " lst))
     (#\? (list "" "\"~s*\"?" "\"~s*\" or " "\"~s*\", " lst))
     (otherwise
      (list "" "\"~s*\"" "\"~s*\" or " "\"~s*\", " lst))))))

(defun fmt1 (str alist col channel state evisc-tuple)

; WARNING:  The master copy of the tilde-directives list is in :DOC fmt.

  (declare (type (signed-byte 30) col))
  (the2s
   (signed-byte 30)
   (mv-let (col state)
           (fmt0 (the-string! str 'fmt1) alist 0
                 (the-fixnum! (length str) 'fmt1)
                 (the-fixnum! col 'fmt1)
                 channel state evisc-tuple)
           (declare (type (signed-byte 30) col))
           (prog2$ (and (eq channel *standard-co*)
                        (maybe-finish-output$ *standard-co* state))
                   (mv col state)))))

(defun fmt (str alist channel state evisc-tuple)

; WARNING: IF you change the list of tilde-directives, change the copy of it in
; the :DOC for fmt1 and fms.

; For a discussion of our style of pretty-printing, see
; http://www.cs.utexas.edu/~boyer/pretty-print.pdf.

  (the2s
   (signed-byte 30)
   (pprogn
    (newline channel state)
    (fmt1 str alist 0 channel state evisc-tuple))))

(defun fms (str alist channel state evisc-tuple)

; WARNING: The master copy of the tilde-directives list is in :DOC fmt.

  (pprogn
   (newline channel state)
   (mv-let (col state)
           (fmt1 str alist 0 channel state evisc-tuple)
           (declare (ignore col))
           state)))

(defun fmt1! (str alist col channel state evisc-tuple)

; WARNING: The master copy of the tilde-directives list is in :DOC fmt.

  (mv-let (erp col state)
          (state-global-let*
           ((write-for-read t))
           (mv-let (col state)
                   (fmt1 str alist col channel state evisc-tuple)
                   (mv nil col state)))
          (declare (ignore erp))
          (mv col state)))

(defun fmt! (str alist channel state evisc-tuple)

; WARNING: The master copy of the tilde-directives list is in :DOC fmt.

  (mv-let (erp col state)
          (state-global-let*
           ((write-for-read t))
           (mv-let (col state)
                   (fmt str alist channel state evisc-tuple)
                   (mv nil col state)))
          (declare (ignore erp))
          (mv col state)))

(defun fms! (str alist channel state evisc-tuple)

; WARNING: The master copy of the tilde-directives list is in :DOC fmt.

  (mv-let (erp val state)
          (state-global-let*
           ((write-for-read t))
           (pprogn (fms str alist channel state evisc-tuple)
                   (mv nil nil state)))
          (declare (ignore erp val))
          state))

(defmacro fmx (str &rest args)
  (declare (xargs :guard (<= (length args) 10)))
  `(fmt ,str ,(make-fmt-bindings '(#\0 #\1 #\2 #\3 #\4
                                   #\5 #\6 #\7 #\8 #\9)
                                 args)
        *standard-co* state nil))

(defun fmt-doc-example1 (lst i)
  (cond ((null lst) nil)
        (t (cons (cons "~c0 (~n1)~tc~y2~|"
                       (list (cons #\0 (cons i 5))
                             (cons #\1 (list i))
                             (cons #\2 (car lst))))
                 (fmt-doc-example1 (cdr lst) (1+ i))))))

(defun fmt-doc-example (x state)
  (fmt "Here is a true list:  ~x0.  It has ~#1~[no elements~/a single ~
        element~/~n2 elements~], ~@3~%~%We could print each element in square ~
        brackets:~%(~*4).  And if we wished to itemize them into column 15 we ~
        could do it like this~%0123456789012345~%~*5End of example."
       (list (cons #\0 x)
             (cons #\1 (cond ((null x) 0) ((null (cdr x)) 1)(t 2)))
             (cons #\2 (length x))
             (cons #\3 (cond ((< (length x) 3) "and so we can't print the third one!")
                             (t (cons "the third of which is ~x0."
                                      (list (cons #\0 (caddr x)))))))
             (cons #\4 (list "[empty]"
                             "[the end: ~y*]"
                             "[almost there: ~y*], "
                             "[~y*], "
                             x))
             (cons #\5 (list* "" "~@*" "~@*" "~@*"
                              (fmt-doc-example1 x 0)
                              (list (cons #\c 15)))))
         *standard-co* state nil))

(defun fmt-abbrev1 (str alist col channel state suffix-msg)
  (pprogn
   (f-put-global 'evisc-hitp-without-iprint nil state)
   (mv-let (col state)
           (fmt1 str alist col channel state (abbrev-evisc-tuple state))
           (fmt1 "~@0~@1"
                 (list
                  (cons #\0
                        (cond ((f-get-global 'evisc-hitp-without-iprint
                                             state)
                               (assert$
                                (not (iprint-enabledp state))
                                "~|(See :DOC set-iprint to be able to see ~
                                 elided values in this message.)"))
                              (t "")))
                  (cons #\1 suffix-msg))
                 col channel state nil))))

(defun fmt-abbrev (str alist col channel state suffix-msg)
  (mv-let (col state)
          (fmt-abbrev1 str alist col channel state suffix-msg)
          (declare (ignore col))
          state))

(defconst *fmt-ctx-spacers*
  '(defun
     #+:non-standard-analysis defun-std
     mutual-recursion
     defuns
     defthm
     #+:non-standard-analysis defthm-std
     defaxiom
     defconst
     defstobj defabsstobj
     defpkg
     deflabel
     defdoc
     deftheory
     defchoose
     verify-guards
     verify-termination
     defmacro
     in-theory
     in-arithmetic-theory
     regenerate-tau-database
     push-untouchable
     remove-untouchable
     reset-prehistory
     set-body
     table
     encapsulate
     include-book))

(defun fmt-ctx (ctx col channel state)

; We print the context in which an error has occurred.  If infix printing is
; being used (infixp = t or :out) then ctx is just the event form itself and we
; print it with evisceration.  Otherwise, we are more efficient in our choice
; of ctx and we interpret it according to its type, to make it convenient to
; construct the more common contexts.  If ctx is nil, we print nothing.  If ctx
; is a symbol, we print it from #\0 via "~x0".  If ctx is a pair whose car is a
; symbol, we print its car and cdr from #\0 and #\1 respectively with "(~x0 ~x1
; ...)".  Otherwise, we print it from #\0 with "~@0".

; We print no other words, spaces or punctuation.  We return the new
; col and state.

  (declare (type (signed-byte 30) col))

; The following bit of raw-Lisp code can be useful when observing
; "ACL2 Error in T:".

; #-acl2-loop-only
; (when (eq ctx t) (break))

  (the2s
   (signed-byte 30)
   (cond ((output-in-infixp state)
          (fmt1 "~p0"
                (list (cons #\0 ctx))
                col channel state
                (evisc-tuple 1 2 nil nil)))
         ((null ctx)
          (mv col state))
         ((symbolp ctx)
          (fmt1 "~x0" (list (cons #\0 ctx)) col channel state nil))
         ((and (consp ctx)
               (symbolp (car ctx)))
          (fmt1 "(~@0~x1 ~x2 ...)"
                (list (cons #\0
                            (if (member-eq (car ctx) *fmt-ctx-spacers*) " " ""))
                      (cons #\1 (car ctx))
                      (cons #\2 (cdr ctx)))
                col channel state nil))
         (t (fmt-abbrev1 "~@0" (list (cons #\0 ctx)) col channel state "")))))

(defun fmt-in-ctx (ctx col channel state)

; We print the phrase " in ctx:  ", if ctx is non-nil, and return
; the new col and state.

  (declare (type (signed-byte 30) col))
  (the2s
   (signed-byte 30)
   (cond ((null ctx)
          (fmt1 ":  " nil col channel state nil))
         (t (mv-let (col state)
                    (fmt1 " in " nil col channel state nil)
                    (mv-let (col state)
                            (fmt-ctx ctx col channel state)
                            (fmt1 ":  " nil col channel state nil)))))))

(defun error-fms-channel (hardp ctx str alist channel state)

; This function prints the "ACL2 Error" banner and ctx, then the
; user's str and alist, and then two carriage returns.  It returns state.

; Historical Note about ACL2

; Once upon a time we accomplished all this with something like: "ACL2
; Error (in ~xc): ~@s~%~%" and it bound #\c and #\s to ctx and str in
; alist.  That suffers from the fact that it may overwrite the user's
; bindings of #\c and #\s -- unlikely if this error call was generated
; by our er macro.  We rewrote the function this way simply so we
; would not have to remember that some variables are special.

  (mv-let (col state)
          (fmt1 (if hardp
                    "~%HARD ACL2 ERROR"
                  "~%ACL2 Error")
                nil 0 channel state nil)
          (mv-let (col state)
                  (fmt-in-ctx ctx col channel state)
                  (fmt-abbrev str alist col channel state ""))))

(defun error-fms (hardp ctx str alist state)

; See error-fms-channel.  Here we also print extra newlines.

; Keep in sync with error-fms-cw.

  (with-output-lock
   (let ((chan (f-get-global 'standard-co state)))
     (pprogn (newline chan state)
             (error-fms-channel hardp ctx str alist chan state)
             (newline chan state)
             (newline chan state)))))

#-acl2-loop-only
(defvar *accumulated-warnings* nil)

(defun push-warning-frame (state)
  #-acl2-loop-only
  (setq *accumulated-warnings*
        (cons nil *accumulated-warnings*))
  state)

(defun absorb-frame (lst stk)
  (if (consp stk)
      (cons (union-equal lst (car stk))
            (cdr stk))
    stk))

(defun pop-warning-frame (accum-p state)

; When a "compound" event has a "sub-event" that generates warnings, we want
; the warning strings from the sub-event's summary to appear in the parent
; event's summary.  Accum-p should be nil if and only if the sub-event whose
; warning frame we are popping had its warnings suppressed.

; Starting after Version_4.1, we use the ACL2 oracle to explain warning frames.
; Previously we kept these frames with a state global variable,
; 'accumulated-warnings, rather than in the raw lisp variable,
; *accumulated-warnings*.  But then we introduced warning$-cw1 to support the
; definitions of translate1-cmp and translate-cmp, which do not modify the ACL2
; state.  Since warning$-cw1 uses a wormhole, the warning frames based on a
; state global variable were unavailable when printing warning summaries.

  #+acl2-loop-only
  (declare (ignore accum-p))
  #+acl2-loop-only
  (mv-let (erp val state)
          (read-acl2-oracle state)
          (declare (ignore erp))
          (mv val state))
  #-acl2-loop-only
  (let ((stk *accumulated-warnings*))
    (cond ((consp stk)
           (progn (setq *accumulated-warnings*
                        (if accum-p
                            (absorb-frame (car stk)
                                          (cdr stk))
                          (cdr stk)))
                  (mv (car stk) state)))
          (t (mv (er hard 'pop-warning-frame
                     "The 'accumulated-warnings stack is empty.")
                 state)))))

(defun push-warning (summary state)
  #+acl2-loop-only
  (declare (ignore summary))
  #-acl2-loop-only
  (when (consp *accumulated-warnings*)

; We used to cause an error, shown below, if the above test fails.  But
; WARNINGs are increasingly used by non-events, such as :trans and (thm ...)
; and rather than protect them all with push-warning-frame/pop-warning-frame we
; are just adopting the policy of not pushing warnings if the stack isn't set
; up for them.  Here is the old code.

;            (prog2$ (er hard 'push-warning
;                        "The 'accumulated-warnings stack is empty but we were ~
;                         asked to add ~x0 to the top frame."
;                        summary)
;                     state)

    (setq *accumulated-warnings*
          (cons (add-to-set-equal summary (car *accumulated-warnings*))
                (cdr *accumulated-warnings*))))
  state)

(defun member-string-equal (str lst)
  (cond
   ((endp lst) nil)
   (t (or (string-equal str (car lst))
          (member-string-equal str (cdr lst))))))

(defabbrev flambda-applicationp (term)

; Term is assumed to be nvariablep.

  (consp (car term)))

(defabbrev lambda-applicationp (term)
  (and (consp term)
       (flambda-applicationp term)))

(defabbrev flambdap (fn)

; Fn is assumed to be the fn-symb of some term.

  (consp fn))

(defabbrev lambda-formals (x) (cadr x))

(defabbrev lambda-body (x) (caddr x))

(defabbrev make-lambda (args body)
  (list 'lambda args body))

(defabbrev make-let (bindings body)
  (list 'let bindings body))

(defun doubleton-list-p (x)
  (cond ((atom x) (equal x nil))
        (t (and (true-listp (car x))
                (eql (length (car x)) 2)
                (doubleton-list-p (cdr x))))))

(defmacro er-let* (alist body)

; This macro introduces the variable er-let-star-use-nowhere-else.
; The user who uses that variable in his forms is likely to be
; disappointed by the fact that we rebind it.

; Keep in sync with er-let*@par.

  (declare (xargs :guard (and (doubleton-list-p alist)
                              (symbol-alistp alist))))
  (cond ((null alist)
         (list 'check-vars-not-free
               '(er-let-star-use-nowhere-else)
               body))
        (t (list 'mv-let
                 (list 'er-let-star-use-nowhere-else
                       (caar alist)
                       'state)
                 (cadar alist)
                 (list 'cond
                       (list 'er-let-star-use-nowhere-else
                             (list 'mv
                                   'er-let-star-use-nowhere-else
                                   (caar alist)
                                   'state))
                       (list t (list 'er-let* (cdr alist) body)))))))

#+acl2-par
(defmacro er-let*@par (alist body)

; Keep in sync with er-let*.

; This macro introduces the variable er-let-star-use-nowhere-else.
; The user who uses that variable in his forms is likely to be
; disappointed by the fact that we rebind it.

  (declare (xargs :guard (and (doubleton-list-p alist)
                              (symbol-alistp alist))))
  (cond ((null alist)
         (list 'check-vars-not-free
               '(er-let-star-use-nowhere-else)
               body))
        (t (list 'mv-let
                 (list 'er-let-star-use-nowhere-else
                       (caar alist))
                 (cadar alist)
                 (list 'cond
                       (list 'er-let-star-use-nowhere-else
                             (list 'mv
                                   'er-let-star-use-nowhere-else
                                   (caar alist)))
                       (list t (list 'er-let*@par (cdr alist) body)))))))

(defmacro match (x pat)
  (list 'case-match x (list pat t)))

(defmacro match! (x pat)
  (list 'or (list 'case-match x
                  (list pat '(value nil)))
        (list 'er 'soft nil
              "The form ~x0 was supposed to match the pattern ~x1."
              x (kwote pat))))

(defun def-basic-type-sets1 (lst i)
  (declare (xargs :guard (and (integerp i)
                              (true-listp lst))))
  (cond ((null lst) nil)
        (t (cons (list 'defconst (car lst) (list 'the-type-set (expt 2 i)))
                 (def-basic-type-sets1 (cdr lst) (+ i 1))))))

(defmacro def-basic-type-sets (&rest lst)
  (let ((n (length lst)))
    `(progn
       (defconst *actual-primitive-types* ',lst)
       (defconst *min-type-set* (- (expt 2 ,n)))
       (defconst *max-type-set* (- (expt 2 ,n) 1))
       (defmacro the-type-set (x)

; Warning: Keep this definition in sync with the type declaration in
; ts-subsetp0 and ts-subsetp.

         `(the (integer ,*min-type-set* ,*max-type-set*) ,x))
       ,@(def-basic-type-sets1 lst 0))))

(defun list-of-the-type-set (x)
  (cond ((consp x)
         (cons (list 'the-type-set (car x))
               (list-of-the-type-set (cdr x))))
        (t nil)))

(defmacro ts= (a b)
  (list '= (list 'the-type-set a) (list 'the-type-set b)))

; We'll create fancier versions of ts-complement0, ts-union0, and
; ts-intersection0 once we have defined the basic type sets.

(defmacro ts-complement0 (x)
  (list 'the-type-set (list 'lognot (list 'the-type-set x))))

(defmacro ts-complementp (x)
  (list 'minusp x))

(defun ts-union0-fn (x)
  (list 'the-type-set
        (cond ((null x) '*ts-empty*)
              ((null (cdr x)) (car x))
              (t (xxxjoin 'logior
                          (list-of-the-type-set x))))))

(defmacro ts-union0 (&rest x)
  (declare (xargs :guard (true-listp x)))
  (ts-union0-fn x))

(defmacro ts-intersection0 (&rest x)
  (list 'the-type-set
        (cons 'logand (list-of-the-type-set x))))

(defmacro ts-disjointp (&rest x)
  (list 'ts= (cons 'ts-intersection x) '*ts-empty*))

(defmacro ts-intersectp (&rest x)
  (list 'not (list 'ts= (cons 'ts-intersection x) '*ts-empty*)))

; We do not define ts-subsetp0, both because we don't need it and because if we
; do define it, we will be tempted to add the declaration found in ts-subsetp,
; yet we have not yet defined *min-type-set* or *max-type-set*.

(defun ts-builder-case-listp (x)

; A legal ts-builder case list is a list of the form
;    ((key1 val1 ...) (key2 val2 ...) ... (keyk valk ...))
; where none of the keys is 'otherwise or 't except possibly keyk and
; every key is a symbolp if keyk is 'otherwise or 't.

; This function returns t, nil, or 'otherwise.  A non-nil value means
; that x is a legal ts-builder case list.  If it returns 'otherwise,
; it means keyk is an 'otherwise or a 't clause.  That aspect of the
; function is not used outside of its definition, but it is used in
; the definition below.

; If keyk is an 'otherwise or 't then each of the other keys will
; occur twice in the expanded form of the ts-builder expression and
; hence those keys must all be symbols.

  (cond ((atom x) (eq x nil))
        ((and (consp (car x))
              (true-listp (car x))
              (not (null (cdr (car x)))))
         (cond ((or (eq t (car (car x)))
                    (eq 'otherwise (car (car x))))
                (cond ((null (cdr x)) 'otherwise)
                      (t nil)))
               (t (let ((ans (ts-builder-case-listp (cdr x))))
                    (cond ((eq ans 'otherwise)
                           (cond ((symbolp (car (car x)))
                                  'otherwise)
                                 (t nil)))
                          (t ans))))))
        (t nil)))

(defun ts-builder-macro1 (x case-lst seen)
  (declare (xargs :guard (and (symbolp x)
                              (ts-builder-case-listp case-lst))))
  (cond ((null case-lst) nil)
        ((or (eq (caar case-lst) t)
             (eq (caar case-lst) 'otherwise))
         (sublis (list (cons 'x x)
                       (cons 'seen seen)
                       (cons 'ts2 (cadr (car case-lst))))
                 '((cond ((ts-intersectp x (ts-complement0 (ts-union0 . seen)))
                          ts2)
                         (t *ts-empty*)))))
        (t (cons (sublis (list (cons 'x x)
                               (cons 'ts1 (caar case-lst))
                               (cons 'ts2 (cadr (car case-lst))))
                         '(cond ((ts-intersectp x ts1) ts2)
                                (t *ts-empty*)))
                 (ts-builder-macro1 x (cdr case-lst) (cons (caar case-lst)
                                                           seen))))))

(defun ts-builder-macro (x case-lst)
  (declare (xargs :guard (and (symbolp x)
                              (ts-builder-case-listp case-lst))))
  (cons 'ts-union
        (ts-builder-macro1 x case-lst nil)))

(defmacro ts-builder (&rest args)
; (declare (xargs :guard (and (consp args)
;                        (symbolp (car args))
;                        (ts-builder-case-listp (cdr args)))))
  (ts-builder-macro (car args) (cdr args)))

(defabbrev strip-not (term)

; A typical use of this macro is:
; (mv-let (not-flg atm) (strip-not term)
;         ...body...)
; which has the effect of binding not-flg to T and atm to x if term
; is of the form (NOT x) and binding not-flg to NIL and atm to term
; otherwise.

  (cond ((and (nvariablep term)
;             (nquotep term)
              (eq (ffn-symb term) 'not))
         (mv t (fargn term 1)))
        (t (mv nil term))))

; The ACL2 Record Facilities

; Our record facility gives us the ability to declare "new" types of
; structures which are represented as lists.  If desired the lists
; are tagged with the name of the new record type.  Otherwise they are
; not tagged and are called "cheap" records.

; The expression (DEFREC SHIP (X . Y) NIL) declares SHIP to
; be a tagged (non-cheap) record of two components X and Y.  An
; example concrete SHIP is '(SHIP 2 . 4).  Note that cheapness refers
; only to whether the record is tagged and whether the tag is tested
; upon access and change, not whether the final cdr is used.

; To make a ship:  (MAKE SHIP :X x :Y y) or (MAKE SHIP :Y y :X x).
; To access the Xth component of the ship object obj: (ACCESS SHIP obj :X).
; To change the Xth component to val: (CHANGE SHIP obj :X val).
; Note the use of keywords in these forms.

; It is possible to change several fields at once, e.g.,
; (CHANGE SHIP obj :X val-x :Y val-y).  In general, to cons up a changed
; record one only does the conses necessary.

; The implementation of records is as follows.  DEFREC expands
; into a collection of macro definitions for certain generated function
; symbols.  In the example above we define the macros:

; |Make SHIP record|
; |Access SHIP record field X|
; |Access SHIP record field Y|
; |Change SHIP record fields|

; The macro expression (MAKE SHIP ...) expands to a call of the first
; function.  (ACCESS SHIP ... :X) expands to a call of the second.
; (CHANGE SHIP obj :X val-x :Y val-y) expands to
; (|Change SHIP record fields| obj :X val-x :Y val-y).

; The five new symbols above are defined as macros that further expand
; into raw CAR/CDR nests if the record is cheap and a similar nest
; that first checks the type of the record otherwise.

; In using the record facility I have sometimes pondered which fields I should
; allocate where to maximize access speed.  Other times I have just laid them
; out in an arbitrary fashion.  In any case, the following functions might be
; useful if you are wondering how to lay out a record.  That is, grab the
; following progn and execute it in the full ACL2 system.  (It cannot be
; executed at this point in basis.lisp because it uses functions defined
; elsewhere; it is here only to be easy to find when looking up the comments
; about records.)  Note that it changes the default-defun-mode to :program.  Then
; invoke :sbt n, where n is an integer.

; For example
; ACL2 g>:sbt 5

; The Binary Trees with Five Tips
; 2.400  ((2 . 2) 2 3 . 3)
; 2.600  (1 (3 . 3) 3 . 3)
; 2.800  (1 2 3 4 . 4)

; Sbt will print out all of the interesting binary trees with the
; given number of tips.  The integer appearing at a tip is the number
; of car/cdrs necessary to access that field of a cheap record laid
; out as shown.  That is also the number of conses required to change
; that single field.  The decimal number in the left column is the
; average number of car/cdrs required to access a field, assuming all
; fields are accessed equally often.  The number of trees generated
; grows exponentially with n.  Roughly 100 trees are printed for size
; 10.  Beware!

; The function (analyze-tree x state) is also helpful.  E.g.,

; ACL2 g>(analyze-tree '((type-alist . term) cl-ids rewrittenp
;                          force-flg . rune-or-non-rune)
;                        state)

; Shape:  ((2 . 2) 2 3 4 . 4)
; Field Depths:
; ((TYPE-ALIST . 2)
;  (TERM . 2)
;  (CL-IDS . 2)
;  (REWRITTENP . 3)
;  (FORCE-FLG . 4)
;  (RUNE-OR-NON-RUNE . 4))
; Avg Depth:  2.833

; (progn
;   (program)
;   (defun bump-binary-tree (tree)
;     (cond ((atom tree) (1+ tree))
;           (t (cons (bump-binary-tree (car tree))
;                    (bump-binary-tree (cdr tree))))))
;
;   (defun cons-binary-trees (t1 t2)
;     (cons (bump-binary-tree t1) (bump-binary-tree t2)))
;
;   (defun combine-binary-trees1 (t1 lst2 ans)
;     (cond ((null lst2) ans)
;           (t (combine-binary-trees1 t1 (cdr lst2)
;                                     (cons (cons-binary-trees t1 (car lst2))
;                                           ans)))))
;
;   (defun combine-binary-trees (lst1 lst2 ans)
;     (cond
;      ((null lst1) ans)
;      (t (combine-binary-trees (cdr lst1)
;                               lst2
;                               (combine-binary-trees1 (car lst1) lst2 ans)))))
;
;   (mutual-recursion
;
;    (defun all-binary-trees1 (i n)
;      (cond ((= i 0) nil)
;            (t (revappend (combine-binary-trees (all-binary-trees i)
;                                                (all-binary-trees (- n i))
;                                                nil)
;                          (all-binary-trees1 (1- i) n)))))
;
;    (defun all-binary-trees (n)
;      (cond ((= n 1) (list 0))
;            (t (all-binary-trees1 (floor n 2) n))))
;    )
;
;   (defun total-access-time-binary-tree (x)
;     (cond ((atom x) x)
;           (t (+ (total-access-time-binary-tree (car x))
;                 (total-access-time-binary-tree (cdr x))))))
;
;   (defun total-access-time-binary-tree-lst (lst)
;
; ; Pairs each tree in lst with its total-access-time.
;
;     (cond ((null lst) nil)
;           (t (cons (cons (total-access-time-binary-tree (car lst))
;                          (car lst))
;                    (total-access-time-binary-tree-lst (cdr lst))))))
;
;   (defun show-binary-trees1 (n lst state)
;     (cond ((null lst) state)
;           (t (let* ((tat (floor (* (caar lst) 1000) n))
;                     (d0 (floor tat 1000))
;                     (d1 (- (floor tat 100) (* d0 10)))
;                     (d2 (- (floor tat 10) (+ (* d0 100) (* d1 10))))
;                     (d3 (- tat (+ (* d0 1000) (* d1 100) (* d2 10)))))
;
;                (pprogn
;                 (mv-let (col state)
;                         (fmt1 "~x0.~x1~x2~x3  ~x4~%"
;                               (list (cons #\0 d0)
;                                     (cons #\1 d1)
;                                     (cons #\2 d2)
;                                     (cons #\3 d3)
;                                     (cons #\4 (cdar lst)))
;                               0
;                               *standard-co* state nil)
;                         (declare (ignore col))
;                         state)
;                 (show-binary-trees1 n (cdr lst) state))))))
;
;   (defun show-binary-trees (n state)
;     (let ((lst (reverse
;                 (merge-sort-car->
;                  (total-access-time-binary-tree-lst
;                   (all-binary-trees n))))))
;       (pprogn
;        (fms "The Binary Trees with ~N0 Tips~%"
;             (list (cons #\0 n))
;             *standard-co* state nil)
;        (show-binary-trees1 n lst state))))
;
;   (defun analyze-tree1 (x i)
;     (cond ((atom x) i)
;           (t (cons (analyze-tree1 (car x) (1+ i))
;                    (analyze-tree1 (cdr x) (1+ i))))))
;
;   (defun analyze-tree2 (x i)
;     (cond ((atom x) (list (cons x i)))
;           (t (append (analyze-tree2 (car x) (1+  i))
;                      (analyze-tree2 (cdr x) (1+  i))))))
;
;   (defun analyze-tree3 (x)
;     (cond ((atom x) 1)
;           (t (+ (analyze-tree3 (car x)) (analyze-tree3 (cdr x))))))
;
;   (defun analyze-tree (x state)
;     (let* ((binary-tree (analyze-tree1 x 0))
;            (alist (analyze-tree2 x 0))
;            (n (analyze-tree3 x))
;            (k (total-access-time-binary-tree binary-tree)))
;       (let* ((tat (floor (* k 1000) n))
;              (d0 (floor tat 1000))
;              (d1 (- (floor tat 100) (* d0 10)))
;              (d2 (- (floor tat 10) (+ (* d0 100) (* d1 10))))
;              (d3 (- tat (+ (* d0 1000) (* d1 100) (* d2 10)))))
;         (pprogn
;          (fms "Shape:  ~x0~%Field Depths:  ~x1~%Avg Depth:  ~x2.~x3~x4~x5~%"
;               (list (cons #\0 binary-tree)
;                     (cons #\1 alist)
;                     (cons #\2 d0)
;                     (cons #\3 d1)
;                     (cons #\4 d2)
;                     (cons #\5 d3))
;               *standard-co* state nil)
;          (value :invisible)))))
;
;   (defmacro sbt (n) `(pprogn (show-binary-trees ,n state) (value :invisible))))
;

(defun record-maker-function-name (name)
  (intern-in-package-of-symbol
   (coerce (append (coerce "Make " 'list)
                   (coerce (symbol-name name) 'list)
                   (coerce " record" 'list))
           'string)
   name))

; Record-accessor-function-name is now in axioms.lisp.

(defun record-changer-function-name (name)
  (intern-in-package-of-symbol
   (coerce
    (append (coerce "Change " 'list)
            (coerce (symbol-name name) 'list)
            (coerce " record fields" 'list))
    'string)
   name))

(defmacro make (&rest args)
  (cond ((keyword-value-listp (cdr args))
         (cons (record-maker-function-name (car args)) (cdr args)))
        (t (er hard 'record-error
               "Make was given a non-keyword as a field specifier.  ~
                The offending form is ~x0."
               (cons 'make args)))))

; Access is now in axioms.lisp.

(defmacro change (&rest args)
  (cond ((keyword-value-listp (cddr args))
         (cons (record-changer-function-name (car args)) (cdr args)))
        (t (er hard 'record-error
               "Change was given a non-keyword as a field specifier.  ~
                The offending form is ~x0."
               (cons 'change args)))))

(defun make-record-car-cdrs1 (lst var)
  (cond ((null lst) var)
        (t (list (car lst) (make-record-car-cdrs1 (cdr lst) var)))))

(defun make-record-car-cdrs (field-layout car-cdr-lst)
  (cond ((atom field-layout)
         (cond ((null field-layout) nil)
               (t (list (make-record-car-cdrs1 car-cdr-lst field-layout)))))
        (t (append (make-record-car-cdrs (car field-layout)
                                         (cons 'car car-cdr-lst))
                   (make-record-car-cdrs (cdr field-layout)
                                         (cons 'cdr car-cdr-lst))))))

(defun make-record-accessors (name field-lst car-cdrs cheap)
  (cond ((null field-lst) nil)
        (t
         (cons (cond
                (cheap
                 (list 'defabbrev
                       (record-accessor-function-name name (car field-lst))
                       (list (car field-lst))
                       (car car-cdrs)))
                (t (list 'defabbrev
                         (record-accessor-function-name name (car field-lst))
                         (list (car field-lst))
                         (sublis (list (cons 'name name)
                                       (cons 'x (car field-lst))
                                       (cons 'z (car car-cdrs)))
                                 '(prog2$ (or (and (consp x)
                                                   (eq (car x) (quote name)))
                                              (record-error (quote name) x))
                                          z)))))
               (make-record-accessors name
                                      (cdr field-lst)
                                      (cdr car-cdrs)
                                      cheap)))))

(defun symbol-name-tree-occur (sym sym-tree)

; Sym is a symbol -- in fact, a keyword in proper usage -- and
; sym-tree is a tree of symbols.  We ask whether a symbol with
; the same symbol-name as key occurs in sym-tree.  If so, we return
; that symbol.  Otherwise we return nil.

  (cond ((symbolp sym-tree)
         (cond ((equal (symbol-name sym) (symbol-name sym-tree))
                sym-tree)
               (t nil)))
        ((atom sym-tree)
         nil)
        (t (or (symbol-name-tree-occur sym (car sym-tree))
               (symbol-name-tree-occur sym (cdr sym-tree))))))

(defun some-symbol-name-tree-occur (syms sym-tree)
  (cond ((null syms) nil)
        ((symbol-name-tree-occur (car syms) sym-tree) t)
        (t (some-symbol-name-tree-occur (cdr syms) sym-tree))))

(defun make-record-changer-cons (fields field-layout x)

; Fields is the list of keyword field specifiers that are being
; changed.  Field-layout is the user's layout of the record.  X is the
; name of the variable holding the instance of the record.

  (cond ((not (some-symbol-name-tree-occur fields field-layout))
         x)
        ((atom field-layout)
         field-layout)
        (t
         (list 'cons
               (make-record-changer-cons fields
                                         (car field-layout)
                                         (list 'car x))
               (make-record-changer-cons fields
                                         (cdr field-layout)
                                         (list 'cdr x))))))

(defun make-record-changer-let-bindings (field-layout lst)

; Field-layout is the symbol tree provided by the user describing the
; layout of the fields.  Lst is the keyword/value list in a change
; form.  We want to bind each field name to the corresponding value.
; The only reason we take field-layout as an argument is that we
; don't know from :key which package 'key is in.

  (cond ((null lst) nil)
        (t (let ((var (symbol-name-tree-occur (car lst) field-layout)))
             (cond ((null var)
                    (er hard 'record-error
                        "A make or change form has used ~x0 as though ~
                         it were a legal field specifier in a record ~
                         with the layout ~x1."
                        (car lst)
                        field-layout))
                   (t
                    (cons (list var (cadr lst))
                          (make-record-changer-let-bindings field-layout
                                                            (cddr lst)))))))))

(defun make-record-changer-let (name field-layout cheap rec lst)
  (cond
   (cheap
    (list 'let (cons (list 'record-changer-not-to-be-used-elsewhere rec)
                     (make-record-changer-let-bindings field-layout lst))
          (make-record-changer-cons
           (evens lst)
           field-layout
           'record-changer-not-to-be-used-elsewhere)))
   (t
    (list 'let (cons (list 'record-changer-not-to-be-used-elsewhere rec)
                     (make-record-changer-let-bindings field-layout lst))
          (sublis
           (list (cons 'name name)
                 (cons 'cons-nest
                       (make-record-changer-cons
                        (evens lst)
                        field-layout
                        '(cdr record-changer-not-to-be-used-elsewhere))))
           '(prog2$ (or (and (consp record-changer-not-to-be-used-elsewhere)
                             (eq (car record-changer-not-to-be-used-elsewhere)
                                 (quote name)))
                        (record-error (quote name)
                                      record-changer-not-to-be-used-elsewhere))
                    (cons (quote name) cons-nest)))))))

(defun make-record-changer (name field-layout cheap)
  (list 'defmacro
        (record-changer-function-name name)
        '(&rest args)
        (list 'make-record-changer-let
              (kwote name)
              (kwote field-layout)
              cheap
              '(car args)
              '(cdr args))))

(defun make-record-maker-cons (fields field-layout)

; Fields is the list of keyword field specifiers being initialized in
; a record.  Field-layout is the user's specification of the layout.
; We lay down a cons tree isomorphic to field-layout whose tips are
; either the corresponding tip of field-layout or nil according to
; whether the keyword corresponding to the field-layout tip is in fields.

  (cond ((atom field-layout)
         (cond ((some-symbol-name-tree-occur fields field-layout)

; The above call is a little strange isn't it?  Field-layout is an
; atom, a symbol really, and here we are asking whether any element of
; fields symbol-name-tree-occurs in it.  We're really just exploiting
; some-symbol-name-tree-occur to walk down fields for us taking the
; symbol-name of each element and seeing if it occurs in (i.e., in
; this case, is) the symbol name of field-layout.

                field-layout)
               (t nil)))
        (t
         (list 'cons
               (make-record-maker-cons fields
                                       (car field-layout))
               (make-record-maker-cons fields
                                       (cdr field-layout))))))

(defun make-record-maker-let (name field-layout cheap lst)
  (cond
   (cheap
    (list 'let (make-record-changer-let-bindings field-layout lst)
          (make-record-maker-cons (evens lst)
                                  field-layout)))
   (t
    (list 'let (make-record-changer-let-bindings field-layout lst)
          (list 'cons
                (kwote name)
                (make-record-maker-cons (evens lst)
                                        field-layout))))))

(defun make-record-maker (name field-layout cheap)
  (list 'defmacro
        (record-maker-function-name name)
        '(&rest args)
        (list 'make-record-maker-let
              (kwote name)
              (kwote field-layout)
              cheap
              'args)))

(defun make-record-field-lst (field-layout)
  (cond ((atom field-layout)
         (cond ((null field-layout) nil)
               (t (list field-layout))))
        (t (append (make-record-field-lst (car field-layout))
                   (make-record-field-lst (cdr field-layout))))))

(defun record-maker-recognizer-name (name)

; We use the "WEAK-" prefix in order to avoid name clashes with stronger
; recognizers that one may wish to define.

  (declare (xargs :guard (symbolp name)))
  (intern-in-package-of-symbol
   (concatenate 'string "WEAK-" (symbol-name name) "-P")
   name))

(defun make-record-recognizer-body (field-layout)
  (declare (xargs :guard t))
  (cond
   ((consp field-layout)
    (cond
     ((consp (car field-layout))
      (cond
       ((consp (cdr field-layout))
        `(and (consp x)
              (let ((x (car x)))
                ,(make-record-recognizer-body (car field-layout)))
              (let ((x (cdr x)))
                ,(make-record-recognizer-body (cdr field-layout)))))
       (t
        `(and (consp x)
              (let ((x (car x)))
                ,(make-record-recognizer-body (car field-layout)))))))
     ((consp (cdr field-layout))
      `(and (consp x)
            (let ((x (cdr x)))
              ,(make-record-recognizer-body (cdr field-layout)))))
     (t '(consp x))))
   (t t)))

(defun make-record-recognizer (name field-layout cheap recog-name)
  `(defun ,recog-name (x)
     (declare (xargs :mode :logic :guard t))
     ,(cond (cheap (make-record-recognizer-body field-layout))
            (t `(and (consp x)
                     (eq (car x) ',name)
                     (let ((x (cdr x)))
                       ,(make-record-recognizer-body field-layout)))))))

(defun record-macros (name field-layout cheap recog-name)
  (declare (xargs :guard (or recog-name (symbolp name))))
  (let ((recog-name (or recog-name
                        (record-maker-recognizer-name name))))
    (cons 'progn
          (append
           (make-record-accessors name
                                  (make-record-field-lst field-layout)
                                  (make-record-car-cdrs field-layout
                                                        (if cheap nil '(cdr)))
                                  cheap)
           (list (make-record-changer name field-layout cheap)
                 (make-record-maker name field-layout cheap)
                 (make-record-recognizer name field-layout cheap recog-name))))))

; WARNING: If you change the layout of records, you must change
; certain functions that build them in.  Generally, these functions
; are defined before defrec was defined, but need to access
; components.  See the warning associated with defrec rewrite-constant
; for a list of one group of such functions.  You might also search
; for occurrences of the word defrec prior to this definition of it.

(defmacro defrec (name field-lst cheap &optional recog-name)

; Warning: If when cheap = nil, the car of a record is no longer name, then 
; consider changing the definition or use of record-type.

; A recognizer with guard t has is defined using recog-name, if supplied; else,
; by default, its name for (defrec foo ...) is the symbol WEAK-FOO-P, in the
; same package as foo.

  (record-macros name field-lst cheap recog-name))

(defmacro record-type (x)

; X is a non-cheap record, i.e., a record whose defrec has cheap = nil.

  `(car ,x))

(defabbrev equalityp (term)

; Note that the fquotep below is commented out.  This function violates
; our standard rules on the use of ffn-symb but is ok since we are looking
; for 'equal and not for 'quote or any constructor that might be hidden
; inside a quoted term.

  (and (nvariablep term)
;      (not (fquotep term))
       (eq (ffn-symb term) 'equal)))

(defabbrev inequalityp (term)

; Note that the fquotep below is commented out.  This function violates
; our standard rules on the use of ffn-symb but is ok since we are looking
; for 'equal and not for 'quote or any constructor that might be hidden
; inside a quoted term.

  (and (nvariablep term)
;      (not (fquotep term))
       (eq (ffn-symb term) '<)))

(defabbrev consityp (term)

; Consityp is to cons what equalityp is equal:  it recognizes terms
; that are non-evg cons expressions.

  (and (nvariablep term)
       (not (fquotep term))
       (eq (ffn-symb term) 'cons)))

(defun power-rep (n b)
  (if (< n b)
      (list n)
    (cons (rem n b)
          (power-rep (floor n b) b))))

(defun decode-idate (n)
  (let ((tuple (power-rep n 100)))
    (cond
     ((< (len tuple) 6)
      (er hard 'decode-idate
          "Idates are supposed to decode to a list of at least length six ~
           but ~x0 decoded to ~x1."
          n tuple))
     ((equal (len tuple) 6) tuple)
     (t

; In this case, tuple is (secs mins hrs day month yr1 yr2 ...) where 0
; <= yri < 100 and (yr1 yr2 ...) represents a big number, yr, in base
; 100.  Yr is the number of years since 1900.

        (let ((secs (nth 0 tuple))
              (mins (nth 1 tuple))
              (hrs  (nth 2 tuple))
              (day  (nth 3 tuple))
              (mo   (nth 4 tuple))
              (yr (power-eval (cdr (cddddr tuple)) 100)))
          (list secs mins hrs day mo yr))))))

(defun pcd2 (n channel state)
  (declare (xargs :guard (integerp n)))
  (cond ((< n 10)
         (pprogn (princ$ "0" channel state)
                 (princ$ n channel state)))
        (t (princ$ n channel state))))

(defun print-idate (n channel state)
  (let* ((x (decode-idate n))
         (sec (car x))
         (minimum (cadr x))
         (hrs (caddr x))
         (day (cadddr x))
         (mo (car (cddddr x)))
         (yr (cadr (cddddr x))))  ; yr = years since 1900.  It is possible
                                  ; that yr > 99!
    (pprogn
     (princ$ (nth (1- mo)
              '(|January| |February| |March| |April| |May|
                |June| |July| |August| |September|
                |October| |November| |December|))
             channel state)
     (princ$ #\Space channel state)
     (princ$ day channel state)
     (princ$ '|,| channel state)
     (princ$ #\Space channel state)
     (princ$ (+ 1900 yr) channel state)
     (princ$ "  " channel state)
     (pcd2 hrs channel state)
     (princ$ '|:| channel state)
     (pcd2 minimum channel state)
     (princ$ '|:| channel state)
     (pcd2 sec channel state)
     state)))

(defun print-current-idate (channel state)
  (mv-let (d state)
    (read-idate state)
    (print-idate d channel state)))


; Essay on Inhibited Output and the Illusion of Windows

; The "io" in io?, below, stands for "inhibit output".  Roughly speaking, it
; takes an unevaluated symbolic token denoting a "kind" of output, an output
; shape involving STATE, and a form with the indicated output signature.
; If the "kind" of output is currently inhibited, it returns all nils and the
; current state, e.g., (mv nil state nil) in the case where the output
; shape is something like (mv x state y).  If the kind of output is not
; inhibited, the form is evaluated and its value is returned.

; If form always returned an error triple, this could be said as:
; `(cond ((member-eq ',token (f-get-global 'inhibit-output-lst state))
;         (value nil))
;        (t ,form))
; This whole macro is just a simple way to do optionally inhibited output.

; The introduction of an emacs window-based interface, led us to put a little
; more functionality into this macro.  Each kind of output has a window
; associated with it.  If the kind of output is uninhibited, the io? macro
; sends to *standard-co* certain auxiliary output which causes the
; *standard-co* output by form to be shipped to the designated window.

; The association of windows is accomplished via the constant
; *window-descriptions* below which contains elements of the form (token str
; clear cursor-at-top pop-up), where token is a "kind" of output, str
; identifies the associated window, and the remaining components specify
; options for how output to the window is handled by default.  The io? macro
; provides keyword arguments for overriding these defaults.  If :clear t is
; specified, the window is cleared before the text is written into it,
; otherwise the text is appended to the end.  If :cursor-at-top t is specified,
; the cursor is left at the top of the inserted text, otherwise it is left at
; the bottom of the inserted text.  If :pop-up t is specified, the window is
; raised to the top of the desktop, otherwise the window remains where it was.

; We have purposely avoided trying to suggest that windows are objects in ACL2.
; We have no way to create them or manage them.  We merely ship a sequence of
; characters to *standard-co* and let the host do whatever it does with them.
; Extending ACL2 with some window abstraction is a desirable thing to do.  I
; would like to be able to manipulate windows as ACL2 objects.  But that is
; beyond the scope of the current work whose aim is merely to provide a more
; modern interface to ACL2 without doing too much violence to ACL2's
; applicative nature or to its claim to be Common Lisp.  Those two constraints
; make the introduction of true window objects truly interesting.

; Finally io? allows for the entire io process to be illusory.  This occurs if
; the commentp argument is t.  In this case, the io? form is logically
; equivalent to NIL.  The actual output is performed after opening a wormhole
; to state.

(defun io?-nil-output (lst default-bindings)
  (cond ((null lst) nil)
        (t (cons (cond ((eq (car lst) 'state) 'state)
                       ((cadr (assoc-eq (car lst) default-bindings)))
                       (t nil))
                 (io?-nil-output (cdr lst) default-bindings)))))

(defmacro check-exact-free-vars (ctx vars form)

; A typical use of this macro is (check-free-vars io? vars form) which just
; expands to the translation of form provided all vars occurring freely in form
; are among vars and vice-versa.  The first argument is the name of the calling
; routine, which is used in error reporting.

  (declare (xargs :guard (symbol-listp vars)))
  `(translate-and-test
    (lambda (term)
      (let ((vars ',vars)
            (all-vars (all-vars term)))
        (cond ((not (subsetp-eq all-vars vars))
               (msg "Free vars problem with ~x0:  Variable~#1~[~/s~] ~&1 ~
                     occur~#1~[s~/~] in ~x2 even though not declared."
                    ',ctx
                    (set-difference-eq all-vars vars)
                    term))
              ((not (subsetp-eq vars all-vars))
               (msg "Free vars problem with ~x0: Variable~#1~[~/s~] ~&1 ~
                     ~#1~[does~/do~] not occur in ~x2 even though declared."
                    ',ctx
                    (set-difference-eq vars all-vars)
                    term))
              (t t))))
    ,form))

(defun formal-bindings (vars)

; For example, if vars is (ab cd) then return the object
; ((list (quote ab) (list 'quote ab)) (list (quote cd) (list 'quote cd))).

  (if (endp vars)
      nil
    (cons (list 'list
                (list 'quote (car vars))
                (list 'list ''quote (car vars)))
          (formal-bindings (cdr vars)))))

(defrec io-record

; WARNING:  We rely on the shape of this record in io-record-forms.

; Note: As of Version_3.4 we do not use any io-marker other than :ctx.  Earlier
; versions might not have made any real use of those either, writing but not
; reading them.

  (io-marker . form)
  t)

(defmacro io-record-forms (io-records)

; WARNING:  If you change this macro, consider changing (defrec io-record ...)
; too.

  `(strip-cdrs ,io-records))

(defun push-io-record (io-marker form state)
  (f-put-global 'saved-output-reversed
                (cons (make io-record
                            :io-marker io-marker
                            :form form)
                      (f-get-global 'saved-output-reversed state))
                state))

(defun saved-output-token-p (token state)
  (and (f-get-global 'saved-output-p state)
       (or (eq (f-get-global 'saved-output-token-lst state) :all)
           (member-eq token (f-get-global 'saved-output-token-lst state)))))

(defun io?-wormhole-bindings (i vars)
  (declare (xargs :guard (and (true-listp vars)
                              (natp i))))
  (cond ((endp vars) nil)
        (t (cons (list (car vars)
                       `(nth ,i (@ wormhole-input)))
                 (io?-wormhole-bindings (1+ i) (cdr vars))))))

(defmacro io? (token commentp shape vars body
                     &key
                     (clear 'nil clear-argp)
                     (cursor-at-top 'nil cursor-at-top-argp)
                     (pop-up 'nil pop-up-argp)
                     (default-bindings 'nil)
                     (chk-translatable 't))

; Typical use (io? error nil (mv col state) (x y) (fmt ...)), meaning execute
; the fmt statement unless 'error is on 'inhibit-output-lst.  The mv expression
; is the shape of the output produced by the fmt expression, and the list (x y)
; for vars indicates the variables other than state that occur free in that
; expression.  See the comment above, and see the Essay on Saved-output for a
; comment that gives a convenient macro for obtaining the free variables other
; than state that occur free in body.

; Default-bindings is a list of doublets (symbol value).  It is used in order
; to supply a non-nil return value for other than state when io is suppressed.
; For example, fmt returns col and state, as suggested by the third (shape)
; argument below.  Without the :default-bindings, this form would evaluate to
; (mv nil state) if event IO is inhibited.  But there are fixnum declarations
; that require the first return value of fmt to be an integer, and we can
; specify the result in the inhibited case to be (mv 0 state) with the
; following :default-bindings:

; (io? event nil (mv col state) nil (fmt ...) :default-bindings ((col 0)))

; The values in :default-bindings are evaluated, so it would be equivalent to
; replace 0 with (- 4 4), for example.

; Keep argument list in sync with io?@par.

; Chk-translatable is only used when commentp is not nil, to check at translate
; time that the body passes translation relative to the given shape.
; (Otherwise such a check is only made when the wormhole call below is actually
; evaluated.)

  (declare (xargs :guard (and (symbolp token)
                              (symbol-listp vars)
                              (no-duplicatesp vars)
                              (not (member-eq 'state vars))
                              (assoc-eq token *window-descriptions*))))
  (let* ((associated-window (assoc-eq token *window-descriptions*))
         (expansion
          `(let* ((io?-output-inhibitedp
                   (member-eq ',token
                              (f-get-global 'inhibit-output-lst state)))
                  (io?-alist
                   (and (not io?-output-inhibitedp)
                        (list
                         (cons #\w ,(cadr associated-window))
                         (cons #\c ,(if clear-argp
                                        clear
                                      (caddr associated-window)))
                         (cons #\t ,(if cursor-at-top-argp
                                        cursor-at-top
                                      (cadddr associated-window)))
                         (cons #\p ,(if pop-up-argp
                                        pop-up
                                      (car (cddddr associated-window))))

; Peter Dillinger requested the following binding, so that he could specify a
; window prelude string that distinguishes between, for example, "prove",
; "event", and "summary" output, which with the default string would all just
; show up as window 4.

                         (cons #\k ,(symbol-name token))))))
             (pprogn
              (if (or io?-output-inhibitedp
                      (null (f-get-global 'window-interfacep state)))
                  state
                (mv-let (io?-col state)
                        (fmt1! (f-get-global 'window-interface-prelude state)
                               io?-alist 0 *standard-co* state nil)
                        (declare (ignore io?-col))
                        state))
              ,(let ((body
                      `(check-vars-not-free
                        (io?-output-inhibitedp io?-alist)
                        (check-exact-free-vars io? (state ,@vars) ,body)))
                     (nil-output (if (eq shape 'state)
                                     'state
                                   (cons 'mv (io?-nil-output (cdr shape)
                                                             default-bindings))))
                     (postlude
                      `(mv-let
                        (io?-col state)
                        (if (or io?-output-inhibitedp
                                (null (f-get-global 'window-interfacep state)))
                            (mv 0 state)
                          (fmt1! (f-get-global 'window-interface-postlude state)
                                 io?-alist 0 *standard-co* state nil))
                        (declare (ignore io?-col))
                        (check-vars-not-free
                         (io?-output-inhibitedp io?-alist io?-col)
                         ,shape))))
                 (let ((body (if commentp
                                 `(let ,(io?-wormhole-bindings 0 vars)
                                    ,body)
                               body)))
                   (cond
                    ((eq shape 'state)
                     `(pprogn
                       (if io?-output-inhibitedp state ,body)
                       ,postlude))
                    (t `(mv-let ,(cdr shape)
                                (if io?-output-inhibitedp
                                    ,nil-output
                                  ,body)
                                ,postlude)))))))))
    (cond
     (commentp
      (let ((form
             (cond
              ((eq shape 'state)
               `(pprogn ,expansion (value :q)))
              (t
               `(mv-let ,(cdr shape)
                        ,expansion
                        (declare
                         (ignore ,@(remove1-eq 'state (cdr shape))))
                        (value :q))))))
        `(prog2$
          ,(if chk-translatable
               `(chk-translatable ,body ,shape)
             nil)
          (wormhole 'comment-window-io
                    '(lambda (whs)
                       (set-wormhole-entry-code whs :ENTER))
                    (list ,@vars)
                    ',form
                    :ld-error-action :return!
                    :ld-verbose nil
                    :ld-pre-eval-print nil
                    :ld-prompt nil))))
     (t `(pprogn
          (cond ((saved-output-token-p ',token state)
                 (push-io-record nil ; io-marker
                                 (list 'let
                                       (list ,@(formal-bindings vars))
                                       ',expansion)
                                 state))
                (t state))
          ,expansion)))))

#+acl2-par
(defmacro io?@par (token commentp &rest rst)

; This macro is the same as io?, except that it provides the extra property
; that the commentp flag is overridden to use comment-window printing.

; Keep the argument list in sync with io?.

; Parallelism blemish: surround the io? call below with a suitable lock.  Once
; this is done, remove any redundant locks around io?@par calls.

  (declare (ignore commentp))
  `(io? ,token t ,@rst))

(defmacro io?-prove (vars body &rest keyword-args)

; Keep in sync with io?-prove-cw.

  `(io? prove nil state ,vars
        (if (gag-mode) state ,body)
        ,@keyword-args))

(defun output-ignored-p (token state)
  (and (not (saved-output-token-p token state))
       (member-eq token
                  (f-get-global 'inhibit-output-lst state))))

(defun error1 (ctx str alist state)

; Warning: Keep this in sync with error1-safe and error1@par.

  (pprogn
   (io? error nil state (alist str ctx)
        (error-fms nil ctx str alist state))
   (mv t nil state)))

#+acl2-par
(defun error1@par (ctx str alist state)

; Keep in sync with error1.  We accept state so that calls to error1 and
; error1@par look the same.

  (declare (ignore state))
  (prog2$
   (io? error t state (alist str ctx)
        (error-fms nil ctx str alist state)
        :chk-translatable nil)
   (mv@par t nil state)))

(defun error1-safe (ctx str alist state)

; Warning: Keep this in sync with error1.

; Note: One can rely on this returning a value component of nil.

  (pprogn
   (io? error nil state (alist str ctx)
        (error-fms nil ctx str alist state))
   (mv nil nil state)))

(defconst *uninhibited-warning-summaries*
  '("Uncertified"
    "Provisionally certified"
    "Skip-proofs"
    "Defaxioms"
    "Ttags"

; The above are included because of soundness.  But "Compiled file", below, is
; included so that we can see it even when inside include-book, since messages
; printed by missing-compiled-book may assume that such warnings are not
; inhibited.

    "Compiled file"))

(defun warning-off-p1 (summary wrld ld-skip-proofsp)

; This function is used by warning$ to determine whether a given warning should
; be printed.  See also warning-disabled-p, which we can use to avoid needless
; computation on behalf of disabled warnings.

  (or (and summary
           (assoc-string-equal
            summary
            (table-alist 'inhibit-warnings-table wrld)))

; The above is sufficient to turn off (warning$ "string" ...).  But even when
; the above condition isn't met, we turn off all warnings -- with the exception
; of those related to soundness -- while including a book.

      (and (or (eq ld-skip-proofsp 'include-book)
               (eq ld-skip-proofsp 'include-book-with-locals)
               (eq ld-skip-proofsp 'initialize-acl2))
           (not (and summary
                     (member-string-equal
                      summary
                      *uninhibited-warning-summaries*))))))

(defun warning-off-p (summary state)
  (warning-off-p1 summary (w state) (ld-skip-proofsp state)))

(defrec state-vars

; Warning: Keep this in sync with default-state-vars.

  ((hons-enabled safe-mode . temp-touchable-vars)
   .
   (guard-checking-on ld-skip-proofsp
                      temp-touchable-fns . parallel-execution-enabled))
  nil)

(defmacro default-state-vars
  (state-p &key
           (safe-mode 'nil safe-mode-p)
           (temp-touchable-vars 'nil temp-touchable-vars-p)
           (guard-checking-on 't guard-checking-on-p)
           (ld-skip-proofsp 'nil ld-skip-proofsp-p)
           (temp-touchable-fns 'nil temp-touchable-fns-p)
           (parallel-execution-enabled 'nil parallel-execution-enabled-p))

; Warning: Keep this in sync with defrec state-vars.

; State-p is t to indicate that we use the current values of the relevant state
; globals.  Otherwise we use the specified defaults, which are supplied above
; for convenience but can be changed there (i.e., in this code) if better
; default values are found.  The value :hons for state-p is treated like nil,
; except that state-var hons-enabled is t rather than nil.

  (cond ((eq state-p t)
         `(make state-vars
                :hons-enabled (hons-enabledp state)
                :safe-mode
                ,(if safe-mode-p
                     safe-mode
                   '(f-get-global 'safe-mode state))
                :temp-touchable-vars
                ,(if temp-touchable-vars-p
                     temp-touchable-vars
                   '(f-get-global 'temp-touchable-vars state))
                :guard-checking-on
                ,(if guard-checking-on-p
                     guard-checking-on
                   '(f-get-global 'guard-checking-on state))
                :ld-skip-proofsp
                ,(if ld-skip-proofsp-p
                     ld-skip-proofsp
                   '(f-get-global 'ld-skip-proofsp state))
                :temp-touchable-fns
                ,(if temp-touchable-fns-p
                     temp-touchable-fns
                   '(f-get-global 'temp-touchable-fns state))
                :parallel-execution-enabled
                ,(if parallel-execution-enabled-p
                     parallel-execution-enabled
                   '(f-get-global 'parallel-execution-enabled state))))
        (t ; state-p is not t
         `(make state-vars
                :hons-enabled ,(eq state-p :hons)
                :safe-mode ,safe-mode
                :temp-touchable-vars ,temp-touchable-vars
                :guard-checking-on ,guard-checking-on
                :ld-skip-proofsp ,ld-skip-proofsp
                :temp-touchable-fns ,temp-touchable-fns
                :parallel-execution-enabled ,parallel-execution-enabled))))

(defun warning1-body (ctx summary str alist state)
  (let ((channel (f-get-global 'proofs-co state)))
    (pprogn
     (if summary
         (push-warning summary state)
       state)
     (mv-let
      (col state)
      (fmt "ACL2 Warning~#0~[~/ [~s1]~]"
           (list (cons #\0 (if summary 1 0))
                 (cons #\1 summary))
           channel state nil)
      (mv-let (col state)
              (fmt-in-ctx ctx col channel state)
              (fmt-abbrev str alist col channel state "~%~%"))))))

(defmacro warning1-form (commentp)

; See warning1.

  `(mv-let
    (check-warning-off summary)
    (cond ((consp summary)
           (mv nil (car summary)))
          (t (mv t summary)))
    (cond
     ((and check-warning-off
           ,(if commentp
                '(warning-off-p1 summary
                                 wrld
                                 (access state-vars state-vars
                                         :ld-skip-proofsp))
              '(warning-off-p summary state)))
      ,(if commentp nil 'state))

; Note:  There are two io? expressions below.  They are just alike except
; that the first uses the token WARNING! and the other uses WARNING.  Keep
; them that way!

     ((and summary
           (member-string-equal summary *uninhibited-warning-summaries*))
      (io? WARNING! ,commentp state
           (summary ctx alist str)
           (warning1-body ctx summary str alist state)
           :chk-translatable nil))
     (t (io? WARNING ,commentp state
             (summary ctx alist str)
             (warning1-body ctx summary str alist state)
             :chk-translatable nil)))))

(defun warning1 (ctx summary str alist state)

; This function prints the "ACL2 Warning" banner and ctx, then the
; user's summary, str and alist, and then two carriage returns.

  (warning1-form nil))

(defmacro warning$ (&rest args)

; A typical use of this macro might be:
; (warning$ ctx "Loops" "The :REWRITE rule ~x0 loops forever." name) or
; (warning$ ctx nil "The :REWRITE rule ~x0 loops forever." name).
; If the second argument is wrapped in a one-element list, as in
; (warning$ ctx ("Loops") "The :REWRITE rule ~x0 loops forever." name),
; then that argument is quoted, and no check will be made for whether the
; warning is disabled, presumably because we are in a context where we know the
; warning is enabled.

  (list 'warning1
        (car args)

; We seem to have seen a GCL 2.6.7 compiler bug, laying down bogus calls of
; load-time-value, when replacing (consp (cadr args)) with (and (consp (cadr
; args)) (stringp (car (cadr args)))).  But it seems fine to have the semantics
; of warning$ be that conses are quoted in the second argument position.

        (if (consp (cadr args))
            (kwote (cadr args))
          (cadr args))
        (caddr args)
        (make-fmt-bindings '(#\0 #\1 #\2 #\3 #\4
                             #\5 #\6 #\7 #\8 #\9)
                           (cdddr args))
        'state))

(defmacro warning-disabled-p (summary)

; We can use this function to avoid needless computation on behalf of disabled
; warnings.

  (declare (xargs :guard (stringp summary)))
  (let ((tp (if (member-equal summary *uninhibited-warning-summaries*)
                'warning!
              'warning)))
    `(or (output-ignored-p ',tp state)
         (warning-off-p ,summary state))))

(defmacro observation1-body (commentp)
  `(io? observation ,commentp state
        (str alist ctx abbrev-p)
        (let ((channel (f-get-global 'proofs-co state)))
          (mv-let
           (col state)
           (fmt "ACL2 Observation" nil channel state nil)
           (mv-let (col state)
                   (fmt-in-ctx ctx col channel state)
                   (cond (abbrev-p
                          (fmt-abbrev str alist col channel state "~|"))
                         ((null abbrev-p)
                          (mv-let (col state)
                                  (fmt1 str alist col channel state nil)
                                  (declare (ignore col))
                                  (newline channel state)))
                         (t
                          (prog2$ (er hard 'observation1
                                      "The abbrev-p (fourth) argument of ~
                                       observation1 must be t or nil, so the ~
                                       value ~x0 is illegal."
                                      abbrev-p)
                                  state))))))
        :chk-translatable nil))

(defun observation1 (ctx str alist abbrev-p state)


; This function prints the "ACL2 Observation" banner and ctx, then the
; user's str and alist, and then a carriage return.

  (observation1-body nil))

(defun observation1-cw (ctx str alist abbrev-p)
  (observation1-body t))

(defmacro observation (&rest args)

; A typical use of this macro might be:
; (observation ctx "5 :REWRITE rules are being stored under name ~x0." name).

  `(cond
    ((or (eq (ld-skip-proofsp state) 'include-book)
         (eq (ld-skip-proofsp state) 'include-book-with-locals)
         (eq (ld-skip-proofsp state) 'initialize-acl2))
     state)
    (t
     (observation1
      ,(car args)
      ,(cadr args)
      ,(make-fmt-bindings '(#\0 #\1 #\2 #\3 #\4
                            #\5 #\6 #\7 #\8 #\9)
                          (cddr args))
      t
      state))))

(defmacro observation-cw (&rest args)

; See observation.  In #-acl2-par, this macro uses wormholes to avoid modifying
; state, and prints even when including books.  In #+acl2-par, to avoid
; wormholes, which are known not to be thread-safe, we simply call cw.

; See observation.  This macro uses wormholes to avoid accessing state, and
; prints even when including books.

; We considered using the @par naming scheme to define this macro in
; #+acl2-par, but the name would then have "@par" in it, which could jar users.

  #-acl2-par
  `(observation1-cw
    ,(car args)
    ,(cadr args)
    ,(make-fmt-bindings '(#\0 #\1 #\2 #\3 #\4
                          #\5 #\6 #\7 #\8 #\9)
                        (cddr args))
    t)
  #+acl2-par

; Parallelism blemish: consider using *the-live-state* to disable
; observation-cw, i.e., to avoid the cw call below, when observations are
; turned off.  But note that if we have such #-acl2-loop-only code, users might
; be surprised when their own use of observation-cw doesn't benefit from such
; restrictions.

  `(cw ,(cadr args) ,@(cddr args)))

(defun skip-when-logic (str state)
  (pprogn
   (observation 'top-level
                "~s0 events are skipped when the default-defun-mode is ~x1."
                str
                (default-defun-mode-from-state state))
   (mv nil nil state)))

(defun chk-inhibit-output-lst (lst ctx state)
  (cond ((not (true-listp lst))
         (er soft ctx
             "The argument to set-inhibit-output-lst must evaluate to a ~
              true-listp, unlike ~x0."
             lst))
        ((not (subsetp-eq lst *valid-output-names*))
         (er soft ctx
             "The argument to set-inhibit-output-lst must evaluate to a ~
              subset of the list ~X01, but ~x2 contains ~&3."
             *valid-output-names*
             nil
             lst
             (set-difference-eq lst *valid-output-names*)))
        (t (let ((lst (if (member-eq 'warning! lst)
                          (add-to-set-eq 'warning lst)
                        lst)))
             (pprogn (cond ((and (member-eq 'prove lst)
                                 (not (member-eq 'proof-tree lst))
                                 (member-eq 'proof-tree
                                            (f-get-global 'inhibit-output-lst
                                                          state)))
                            (warning$ ctx nil
                                      "The printing of proof-trees is being ~
                                       enabled while the printing of proofs ~
                                       is being disabled.  You may want to ~
                                       execute :STOP-PROOF-TREE in order to ~
                                       inhibit proof-trees as well."))
                           (t state))
                     (value lst))))))

; With er defined, we may now define chk-ld-skip-proofsp.

(defconst *ld-special-error*
  "~x1 is an illegal value for the state global variable ~x0.  See ~
   :DOC ~x0.")

(defun chk-ld-skip-proofsp (val ctx state)
  (declare (xargs :mode :program))
  (cond ((member-eq val
                    '(t nil include-book
                        initialize-acl2 include-book-with-locals))
         (value nil))
        (t (er soft ctx
               *ld-special-error*
               'ld-skip-proofsp val))))

(defun set-ld-skip-proofsp (val state)
  (declare (xargs :mode :program))
  (er-progn
   (chk-ld-skip-proofsp val 'set-ld-skip-proofsp state)
   (pprogn
    (f-put-global 'ld-skip-proofsp val state)
    (value val))))

(defmacro set-ld-skip-proofs (val state)

; Usually the names of our set utilities do not end in "p".  We leave
; set-ld-skip-proofsp for backward compatibility, but we add this version
; for consistency.

  (declare (ignore state)) ; avoid a stobj problem
  `(set-ld-skip-proofsp ,val state))

(defun set-write-acl2x (val state)
  (declare (xargs :guard (state-p state)))
  (er-progn
   (cond ((member-eq val '(t nil)) (value nil))
         ((and (consp val) (null (cdr val)))
          (chk-ld-skip-proofsp (car val) 'set-write-acl2x state))
         (t (er soft 'set-write-acl2x
                "Illegal value for set-write-acl2x, ~x0.  See :DOC ~
                 set-write-acl2x."
                val)))
   (pprogn (f-put-global 'write-acl2x val state)
           (value val))))

;                             CHECK SUMS

; We begin by developing code to compute checksums for files, culminating in
; function check-sum.  (Later we will consider checksums for objects.)

; We can choose any two nonnegative integers for the following two
; constants and still have a check-sum algorithm, provided, (a) that
; (< (* 127 *check-length-exclusive-maximum*) *check-sum-exclusive-maximum*)
; and provided (b) that (* 2 *check-sum-exclusive-maximum*) is of type
; (signed-byte 32).  The first condition assures that the intermediate
; sum we obtain by adding to a running check-sum the product of a
; character code with the current location can be reduced modulo
; *check-sum-exclusive-maximum* by subtracting *check-sum-exclusive-maximum*.
; Choosing primes, as we do, may help avoid some loss of information
; due to cancellation.  Choosing primes that are smaller may lead to
; check sums with less information.

(defconst *check-sum-exclusive-maximum* 268435399
  "268435399 is the first prime below 2^28.  We use integers
   modulo this number as check sums.")

(defconst *check-length-exclusive-maximum* 2097143
  "2097143 is the first prime below 2^21.  We use integers
   modulo this number as indices into the stream we are
   check summing.")

; We actually return check-sums which are in (mod
; *check-sum-exclusive-maximum*).

(defconst *-check-sum-exclusive-maximum* (- *check-sum-exclusive-maximum*))

(defconst *1-check-length-exclusive-maximum*
  (1- *check-length-exclusive-maximum*))

(defun ascii-code! (x)
  (let ((y (char-code x)))
    (cond
     ((or (= y 0) (= y 128))
      1)
     ((< 127 y)
      (- y 128))
     (t y))))

(defun check-sum1 (sum len channel state)
  (declare (type (signed-byte 32) sum len))
  (let ((len (cond ((= len 0) *1-check-length-exclusive-maximum*)
                   (t (the (signed-byte 32) (1- len))))))
    (declare (type (signed-byte 32) len))
    (mv-let (x state)
      (read-char$ channel state)
      (cond ((not (characterp x)) (mv sum state))
            (t (let ((inc (ascii-code! x)))
                 (declare (type (unsigned-byte 7) inc))
                 (cond ((and (= inc 0)
                             (not (eql x #\Tab)))
                        (mv x state))
                       (t (let ((inc (the (unsigned-byte 7)
                                          (cond ((= inc 0) 9) (t inc)))))
                            (declare (type (unsigned-byte 7) inc))
                            (let ((sum (+ sum (the (signed-byte 32)
                                                   (* inc len)))))
                              (declare (type (signed-byte 32) sum))
                              (check-sum1
                               (cond ((>= sum *check-sum-exclusive-maximum*)
                                      (the (signed-byte 32)
                                       (+ sum *-check-sum-exclusive-maximum*)))
                                     (t sum))
                               len channel state)))))))))))

(defun check-sum (channel state)

; This function returns a check-sum on the characters in a stream.
; This function also checks that every character read is either
; #\Newline, #\Tab, or #\Space, or a printing Ascii character.  If the
; first value returned is a character, that character was not legal.
; Otherwise, the first value returned is an integer, the check-sum.

  (check-sum1 0 *1-check-length-exclusive-maximum* channel state))

; We now develop code for computing checksums of objects.  There are two
; separate algorithms, culminating respectively in functions old-check-sum-obj
; and fchecksum-obj.  The first development was used up through ACL2
; Version_3.4, which uses an algorithm similar to that of our file-based
; function, check-sum.  However, the #+hons version of ACL2 was being used on
; large cons trees with significant subtree sharing.  These "galactic" trees
; could have relatively few distinct cons cells but a huge naive node count.
; It was thus desirable to memoize the computation of checksums, which was
; impossible using the existing algorithm because it modified state.

; The second development was contributed by Jared Davis (and is now maintained
; by the ACL2 developers, who are responsible for any errors).  It is amenable
; to memoization and, indeed, fchecksum-obj is memoized in the #+hons version
; of ACL2.  We say more after developing the code for the first algorithm,
; culminating in function check-sum-obj1.

; We turn now to the first development (which is no longer used in ACL2).

(defun check-sum-inc (n state)
  (declare (type (unsigned-byte 7) n))
  (let ((top
         (32-bit-integer-stack-length state)))
    (declare (type (signed-byte 32) top))
    (let ((sum-loc (the (signed-byte 32) (+ top -1)))
          (len-loc (the (signed-byte 32) (+ top -2))))
      (declare (type (signed-byte 32) sum-loc len-loc))
      (let ((sum
             (aref-32-bit-integer-stack sum-loc state)))
        (declare (type (signed-byte 32) sum))
        (let ((len
               (aref-32-bit-integer-stack len-loc state)))
          (declare (type (signed-byte 32) len))
          (let ((len (cond ((= 0 len) *1-check-length-exclusive-maximum*)
                           (t (the (signed-byte 32) (+ len -1))))))
            (declare (type (signed-byte 32) len))
            (let ((state
                   (aset-32-bit-integer-stack len-loc len state)))
              (let ((new-sum
                     (the (signed-byte 32)
                      (+ sum (the (signed-byte 32) (* n len))))))
                (declare (type (signed-byte 32) new-sum))
                (let ((new-sum
                       (cond ((>= new-sum *check-sum-exclusive-maximum*)
                              (the (signed-byte 32)
                               (+ new-sum *-check-sum-exclusive-maximum*)))
                             (t new-sum))))
                  (declare (type (signed-byte 32) new-sum))
                  (aset-32-bit-integer-stack sum-loc new-sum state))))))))))

(defun check-sum-natural (n state)
  (declare (type unsigned-byte n))
  (cond ((<= n 127)
         (check-sum-inc (the (unsigned-byte 7) n) state))
        (t (pprogn (check-sum-inc (the (unsigned-byte 7) (rem n 127)) state)
                   (check-sum-natural (truncate n 127) state)))))

(defun check-sum-string1 (str i len state)
  (declare (type string str))
  (declare (type (signed-byte 32) i len))
  (cond ((= i len) state)
        (t (let ((chr (char str i)))
             (declare (type character chr))
             (let ((code (ascii-code! chr)))
               (declare (type (unsigned-byte 7) code))
               (cond ((> code 127)
                      (f-put-global
                       'check-sum-weirdness (cons str i) state))
                     (t (pprogn (check-sum-inc code state)
                                (check-sum-string1
                                 str
                                 (the (signed-byte 32) (1+ i))
                                 len
                                 state)))))))))

(defun check-sum-string2 (str i len state)

; This function serves the same purpose as check-sum-string1 except
; that no assumption is made that i or len fit into 32 bits.  It
; seems unlikely that this function will ever be called, since it
; seems unlikely that any Lisp will support strings of length 2 billion
; or more, but who knows.

  (declare (type string str))
  (cond ((= i len) state)
        (t (let ((chr (char str i)))
             (let ((code (ascii-code! chr)))
               (cond ((> code 127)
                      (f-put-global
                       'check-sum-weirdness (cons str i) state))
                     (t (pprogn (check-sum-inc code state)
                                (check-sum-string2
                                 str
                                 (1+ i)
                                 len
                                 state)))))))))

(defun check-sum-string (str state)
  (let ((len (the integer (length (the string str)))))
    (cond ((32-bit-integerp len)
           (check-sum-string1 str 0 (the (signed-byte 32) len) state))
          (t (check-sum-string2 str 0 len state)))))

(defun check-sum-obj1 (obj state)
  (cond ((symbolp obj)
         (pprogn (check-sum-inc 1 state)
                 (check-sum-string (symbol-name obj) state)))
        ((stringp obj)
         (pprogn (check-sum-inc 2 state)
                 (check-sum-string obj state)))
        ((rationalp obj)
         (cond ((integerp obj)
                (cond ((< obj 0)
                       (pprogn (check-sum-inc 3 state)
                               (check-sum-natural (- obj) state)))
                      (t (pprogn (check-sum-inc 4 state)
                                 (check-sum-natural obj state)))))
               (t (let ((n (numerator obj)))
                    (pprogn (check-sum-inc 5 state)
                            (check-sum-natural (if (< n 0) (1- (- n)) n) state)
                            (check-sum-natural (denominator obj) state))))))
        ((consp obj)
         (pprogn (check-sum-inc 6 state)
                 (check-sum-obj1 (car obj) state)
                 (cond ((atom (cdr obj))
                        (cond ((cdr obj)
                               (pprogn (check-sum-inc 7 state)
                                       (check-sum-obj1 (cdr obj) state)))
                              (t (check-sum-inc 8 state))))
                       (t (check-sum-obj1 (cdr obj) state)))))
        ((characterp obj)
         (pprogn (check-sum-inc 9 state)
                 (let ((n (ascii-code! obj)))
                   (cond ((< n 128)
                          (check-sum-inc (ascii-code! obj) state))
                         (t (f-put-global
                             'check-sum-weirdness obj state))))))
        ((complex-rationalp obj)
         (pprogn (check-sum-inc 14 state)
                 (check-sum-obj1 (realpart obj) state)
                 (check-sum-obj1 (imagpart obj) state)))
        (t (f-put-global
            'check-sum-weirdness obj state))))

(defun old-check-sum-obj (obj state)

; This function became obsolete after Version_3.4 but we include it in case
; there are situations where it becomes useful again.  It is the culmination of
; our first development of checksums for objects (as discussed above).

; We return a check-sum on obj, using an algorithm similar to that of
; check-sum.  We return a non-integer as the first value if (and only if) the
; obj is not composed entirely of conses, symbols, strings, rationals, complex
; rationals, and characters. If the first value is not an integer, it is one of
; the offending objects encoutered.

; We typically use this function to compute check sums of cert-obj records and
; of objects of the form (cons expansion-alist ev-lst) where ev-lst is the list
; of forms in a book, including the initial in-package, and expansion-alist
; comes from make-event expansion.

  (pprogn
   (extend-32-bit-integer-stack 2 0 state)
   (let ((top
          (32-bit-integer-stack-length state)))
     (let ((sum-loc (+ top -1))
           (len-loc (+ top -2)))
       (pprogn
        (aset-32-bit-integer-stack sum-loc 0 state)
        (aset-32-bit-integer-stack len-loc *1-check-length-exclusive-maximum*
                                   state)
        (f-put-global 'check-sum-weirdness nil state)
        (check-sum-obj1 obj state)
        (let ((ans (aref-32-bit-integer-stack sum-loc state)))
          (pprogn (shrink-32-bit-integer-stack 2 state)
                  (let ((x (f-get-global 'check-sum-weirdness state)))
                    (cond (x (pprogn (f-put-global
                                      'check-sum-weirdness nil state)
                                     (mv x state)))
                          (t (mv ans state)))))))))))

; We now develop code for the second checksum algorithm, contributed by Jared
; Davis (now maintained by the ACL2 developers, who are responsible for any
; errors).  See also the long comment after check-sum-obj, below.

; Our initial attempts however were a problem for GCL, which boxes fixnums
; unless one is careful.  A regression took about 44 or 45 minutes instead of
; 35 or 36 minutes, which is really significant considering that (probably)
; only the checksum code was changed, and one would expect checksums to take a
; trivial fraction of time during a regression.  Therefore, we developed code
; to avoid boxing fixnums in GCL during a common operation: multiplication mod
; M31 = #x7fffffff.  The code below is developed only for defining that
; operation, times-mod-m31; so we could conditionalize with #+gcl all
; definitions below up to times-mod-m31.  We believe that the following is a
; theorem, but we have not proved it (nor even admitted the relevant functions
; into :logic mode):

; (implies (and (natp x) (< x #x7fffffff)
;               (natp y) (< y #x7fffffff))
;          (equal (times-mod-m31 x y)
;                 (rem (* x y) #x7fffffff)))

; We considered using our fancy times-mod-m31 and its subfunctions for other
; than GCL.  The time loss for ACL2h built on CCL 1.2 (actually
; 1.2-r10991M-trunk) on DarwinX8664 was only about 3.2%, which seems worth the
; cost in order to avoid having Lisp-specific code.  However, regression runs
; with ACL2 built on Allegro CL exhibited intermittent checksumming errors.  We
; wonder about a possible compiler bug, since neither heavy addition of checks,
; nor running with safety 3 (both ACL2h on CCL and ACL2 on Allegro CL) showed
; any inappropriate type declarations in the code below, and there were no
; checksumming problems exhibited with CCL, GCL, or SBCL.  Moreover, Allegro CL
; showed significant slow down with the fancy times-mod-m31, not surprisingly
; since Allegro CL supports fixnums of less than 32 bits.  Therefore, we
; decided to use a much simpler times-mod-m31 for all Lisps except GCL.

(defun plus-mod-m31 (u v)

; Add u and v mod M31 = #x7fffffff.

  (declare (type (signed-byte 32) u v))
  (the (signed-byte 32)
       (let ((u (min u v))
             (v (max u v)))
         (declare (type (signed-byte 32) u v))
         (cond ((< u #x40000000) ; 2^30
                (cond ((< v #x40000000) ; 2^30
                       (the (signed-byte 32) (+ u v)))
                      (t
                       (let ((part (+ (the (signed-byte 32)
                                           (logand v #x3FFFFFFF)) ; v - 2^30
                                      u)))
                         (declare (type (signed-byte 32) part))
                         (cond ((< part #x3FFFFFFF)
                                (the (signed-byte 32)
                                     (logior part #x40000000)))
                               ((eql part #x3FFFFFFF)
                                0)
                               (t ; part + 2^30 = part' + 2^31
                                (the (signed-byte 32)
                                     (1+ (the (signed-byte 32)
                                              (logxor part #x40000000))))))))))
               (t (the (signed-byte 32)
                       (- #x7FFFFFFF
                          (the (signed-byte 32)
                               (+ (the (signed-byte 32)
                                       (- #x7FFFFFFF u))
                                  (the (signed-byte 32)
                                       (- #x7FFFFFFF v)))))))))))

(defun double-mod-m31 (x)

; This is an optimization of (plus-mod-m31 x x).

  (declare (type (signed-byte 32) x))
  (the (signed-byte 32)
       (cond ((< x #x40000000) ; 2^30
              (the (signed-byte 32) (ash x 1)))
             (t (the (signed-byte 32)
                     (- #x7FFFFFFF
                        (the (signed-byte 32)
                             (ash (the (signed-byte 32)
                                       (- #x7FFFFFFF x))
                                  1))))))))

(defun times-expt-2-16-mod-m31 (x)

; Given x < M31 = #x7fffffff, we compute 2^16*x mod M31.  The idea is to view x
; as the concatenation of 15-bit chunk H (high) to 16-bit chunk L (low), so
; that reasoning mod M31, 2^16*x = 2^32*H + 2^16*L = 2*H + 2^16*L.  Note that
; if L has its high (15th) bit set, then writing L# for the result of masking
; out that bit, we have [mod M31] 2^16*L = 2^16(2^15 + L#) = 2^31 + 2^16 * L#.
; = 1 + 2^16 * L#.

; We can test this function in CCL, in raw Lisp, as follows.  (It may be too
; slow to do this in GCL since some intermediate results might not be fixnums.)
; It took us about 3.5 minutes (late 2008).

;  (defun test ()
;    (loop for i from 0 to #x7ffffffe
;          when (not (eql (times-expt-2-16-mod-m31 i)
;                         (mod (* #x10000 i) #x7fffffff)))
;          do (return i)))
;  (test)

  (declare (type (signed-byte 32) x))
  (the (signed-byte 32)
       (let ((hi (ash x -16))
             (lo (logand x #x0000ffff)))
         (declare (type (signed-byte 32) hi lo))
         (cond ((eql 0
                     (the (signed-byte 32)
                          (logand lo #x8000))) ; logbitp in GCL seems to box!
                (the (signed-byte 32)
                     (plus-mod-m31 (double-mod-m31 hi)
                                   (the (signed-byte 32)
                                        (ash lo 16)))))
               (t
                (the (signed-byte 32)
                     (plus-mod-m31 (double-mod-m31 hi)
                                   (the (signed-byte 32)
                                        (logior
                                         #x1
                                         (the (signed-byte 32)
                                              (ash (the (signed-byte 32)
                                                        (logand lo #x7fff))
                                                   16)))))))))))

#+(and (not gcl) (not acl2-loop-only))
(declaim (inline times-mod-m31))

(defun times-mod-m31 (u v)

; Note that u or v (or both) can be #x7fffffff, not just less than that number;
; this code will still give the correct result, 0.

; See the comment above about "using our fancy times-mod-m31" for GCL only.

  (declare (type (signed-byte 32) u v))
  (the (signed-byte 32)
       #+(or (not gcl) acl2-loop-only)
       (rem (the (signed-byte 64) (* u v))
            #x7fffffff)
       #+(and gcl (not acl2-loop-only))

; We want to avoid boxing, where we have 32-bit fixnums u and v.  We compute as
; follows:

;   u * v
; = (2^16 u-hi + u-lo) * (2^16 v-hi + v-lo)
; = 2^32 u-hi v-hi + 2^16 u-hi v-lo + 2^16 u-lo v-hi + u-lo v-lo
; = [mod M31 = #x7fffffff]
;   2 u-hi v-hi + 2^16(u-hi*v-lo + u-lo*v-hi) + u-lo*v-lo

; Now u-hi and v-hi are less than 2^15, while u-lo and v-lo are less than
; 2^16.  So we need to be careful with the term u-lo*v-lo.

       (let ((u-hi (ash u -16))
             (u-lo (logand u #x0000ffff))
             (v-hi (ash v -16))
             (v-lo (logand v #x0000ffff)))
         (declare (type (signed-byte 32) u-hi u-lo v-hi v-lo))
         (let ((term1 (double-mod-m31 (the (signed-byte 32)
                                           (* u-hi v-hi))))
               (term2 (times-expt-2-16-mod-m31
                       (plus-mod-m31 (the (signed-byte 32) (* u-hi v-lo))
                                     (the (signed-byte 32) (* u-lo v-hi)))))
               (term3 (cond ((or (eql (the (signed-byte 32)
                                           (logand u-lo #x8000))
                                      0)
                                 (eql (the (signed-byte 32)
                                           (logand v-lo #x8000))
                                      0))
                             (the (signed-byte 32)
                                  (* u-lo v-lo)))
                            (t

; Let H = 2^15, and let u0 and v0 be the results of masking out the high bits
; of u-lo and v-lo, respectively.  So:

;   u-lo * v-lo
; = (H + u0) * (H + v0)
; = H^2 + H*(u0 + v0) + u0*v0

                             (let ((u0 (logand u #x7fff))
                                   (v0 (logand v #x7fff)))
                               (declare (type (signed-byte 32) u0 v0))
                               (plus-mod-m31 #x40000000 ; 2^30
                                             (plus-mod-m31
                                              (the (signed-byte 32)
                                                   (* #x8000 ; 2^15
                                                      (the (signed-byte 32)
                                                           (+ u0 v0))))
                                              (the (signed-byte 32)
                                                   (* u0 v0)))))))))
           (declare (type (signed-byte 32) term1 term2 term3))
           (plus-mod-m31 term1
                         (plus-mod-m31 term2 term3))))))

; Now we can include (our latest version of) Jared's code.

(defun fchecksum-natural-aux (n ans)

; A "functional" checksum for natural numbers.
;
;   N is the natural number we want to checksum.
;   ANS is the answer we have accumulated so far.
;
; Let M31 be 2^31 - 1.  This happens to be the largest representable 32-bit
; signed number using 2's complement arithmetic.  It is also a Mersenne prime.
; Furthermore, let P1 be 392894102, which is a nice, large primitive root of
; M31.  From number theory, we can construct a basic pseudorandom number
; generator as follows:
;
;   rnd0 = seed
;   rnd1 = (rnd0 * P1) mod M31
;   rnd2 = (rnd1 * P1) mod M31
;   ...
;
; And our numbers will not repeat until 2^31 - 1.  In fact, such a generator
; is found in the community book "misc/random."
;
; Our checksum algorithm uses this idea in a slightly different way.  Given a
; 31-bit natural number, K, think of (K * P1) mod M31 as a way to "shuffle" the
; bits of K around in a fairly random manner.  Then, to checksum a (potentially
; large) integer n, we break n up into 31-bit chunks, call them K1, K2, ...,
; Km.  We then compute (Ki * P1) mod M31 for each i, and xor the results all
; together to compute a new, 31-bit checksum.

; A couple of other notes.
;
;  - M31 may be written as #x7FFFFFFF.
;
;  - We recur using (ash n -31), but this computes the same thing as (truncate
;    n (expt 2 31)).
;
;  - We split n into Ki by using (logand n #x7FFFFFFF), which is the same as
;    (rem n (expt 2 31)).

  (declare (type (integer 0 *) n))
  (declare (type (signed-byte 32) ans))
  (the (signed-byte 32)
    (if (eql n 0)
        ans
      (fchecksum-natural-aux (the (integer 0 *) (ash n -31))
                             (the (signed-byte 32)
                               (logxor ans
                                       (the (signed-byte 32)
                                         (times-mod-m31
                                          (logand n #x7FFFFFFF)
                                          392894102))))))))

(defun fchecksum-natural (n)
  (declare (type (integer 0 *) n))
  (the (signed-byte 32)
    (fchecksum-natural-aux n 28371987)))

(defun fchecksum-string1 (str i len ans)

; A "functional" checksum for strings.
;
; This is similar to the case for natural numbers.
;
; We consider the string in 31-bit pieces; each character in the string has,
; associated with it, an 8-bit character code, so we can combine four of these
; codes together to create a 32 bit chunk.  We then simply drop the highest
; resulting bit (which should typically not matter because the character codes
; above 127 are so rarely used).  The remaining 31-bits are be treated just as
; the 31-bit chunks of integers are, but the only twist is that we will use a
; different primitive root so that we come up with different numbers.  In
; particular, we will use 506249751.

; WARNING: Keep this in sync with fchecksum-string2.

  (declare (type string str))
  (declare (type (signed-byte 32) i len ans))
  (the (signed-byte 32)
    (if (>= i len)
        ans
      (let* ((c0 (logand #x7F (the (signed-byte 32)
                                (char-code (the character (char str i))))))
             (i  (+ i 1))
             (c1 (if (>= i len)
                     0
                   (char-code (the character (char str i)))))
             (i  (+ i 1))
             (c2 (if (>= i len)
                     0
                   (char-code (the character (char str i)))))
             (i  (+ i 1))
             (c3 (if (>= i len)
                     0
                   (char-code (the character (char str i)))))
             (bits

; GCL 2.6.7 does needless boxing when we call logior on the four arguments,
; even when each of them is of the form (the (signed-byte 32) xxx).  So the
; code is a bit ugly below.

              (logior (the (signed-byte 32) (ash c0 24))
                      (the (signed-byte 32)
                           (logior (the (signed-byte 32) (ash c1 16))
                                   (the (signed-byte 32)
                                        (logior (the (signed-byte 32)
                                                     (ash c2 8))
                                                (the (signed-byte 32)
                                                     c3))))))))
        (declare (type (signed-byte 32) c0 i c1 c2 c3 bits))
        (fchecksum-string1
         str i len
         (the (signed-byte 32)
           (logxor ans
                   (the (signed-byte 32)
                     (times-mod-m31 bits 506249751)))))))))

(defun fchecksum-string2 (str i len ans)

; Same as above, but we don't assume i, len are (signed-byte 32)'s.

; WARNING: Keep this in sync with fchecksum-string1.

  (declare (type string str))
  (declare (type (signed-byte 32) ans))
  (declare (type (integer 0 *) i len))
  (the (signed-byte 32)
    (if (>= i len)
        ans
      (let* ((c0 (logand #x7F (the (signed-byte 32)
                                (char-code (the character (char str i))))))
             (i  (+ i 1))
             (c1 (if (>= i len)
                     0
                   (char-code (the character (char str i)))))
             (i  (+ i 1))
             (c2 (if (>= i len)
                     0
                   (char-code (the character (char str i)))))
             (i  (+ i 1))
             (c3 (if (>= i len)
                     0
                   (char-code (the character (char str i)))))
             (bits ; see comment in fchecksum-string1 about ugly code below
              (logior (the (signed-byte 32) (ash c0 24))
                      (the (signed-byte 32)
                           (logior (the (signed-byte 32) (ash c1 16))
                                   (the (signed-byte 32)
                                        (logior (the (signed-byte 32)
                                                     (ash c2 8))
                                                (the (signed-byte 32)
                                                     c3))))))))
        (declare (type (signed-byte 32) c0 c1 c2 c3 bits)
                 (type (integer 0 *) i))
        (fchecksum-string2
         str i len
         (the (signed-byte 32)
           (logxor ans
                   (the (signed-byte 32)
                     (times-mod-m31 bits 506249751)))))))))

(defun fchecksum-string (str)
  (declare (type string str))
  (the (signed-byte 32)
       (let ((length (length str)))
         (declare (type (integer 0 *) length))
         (cond ((< length 2147483647) ; so (+ 1 length) is (signed-byte 32)
                (fchecksum-string1 str 0 length

; We scramble the length in order to get a seed.  This number is just another
; primitive root.

                                   (times-mod-m31 (the (signed-byte 32)
                                                       (+ 1 length))
                                                  718273893)))
               (t
                (fchecksum-string2 str 0 length

; As above, but WARNING: Do not use times-mod-m31 here, because length need not
; be a fixnum.

                                   (rem (the integer (* (+ 1 length)
                                                        718273893))
                                        #x7FFFFFFF)))))))

#-(or acl2-loop-only hons)
(defvar *fchecksum-symbol-memo*
  nil)

(defun fchecksum-atom (x)

; X is any atom.  We compute a "functional checksum" of X.
;
; This is pretty straightforward.  For naturals and strings, we just call the
; functions we've developed above.  Otherwise, the object is composed out of
; naturals and strings.  We compute the component-checksums, then "scramble"
; them by multiplying with another primitive root.  Since it is easy to find
; primitive roots, it is easy to scramble in many different ways based on the
; different types we are looking at.

  (the (signed-byte 32)
    (cond ((natp x)
           (fchecksum-natural x))
          ((integerp x)

; It's not a natural, so it's negative.  We compute the code for the absolute
; value, then scramble it with yet another primitive root.

           (let ((abs-code (fchecksum-natural (- x))))
             (declare (type (signed-byte 32) abs-code))
             (times-mod-m31 abs-code 283748912)))
          ((symbolp x)
           (cond
            #-(or hons acl2-loop-only)
            ((and *fchecksum-symbol-memo*
                  (gethash x *fchecksum-symbol-memo*)))
            (t
             (let* ((pkg-code (fchecksum-string (symbol-package-name x)))
                    (sym-code (fchecksum-string (symbol-name x)))
                    (pkg-code-scramble

; We scramble the bits of pkg-code so that it matters that they are in order.
; To do this, we multiply by another primitive root and mod out by M31.

                     (times-mod-m31 pkg-code 938187814)))
               (declare (type (signed-byte 32)
                              pkg-code sym-code pkg-code-scramble))
               (cond #-(or hons acl2-loop-only)
                     (*fchecksum-symbol-memo*
                      (setf (gethash x *fchecksum-symbol-memo*)
                            (logxor pkg-code-scramble sym-code)))
                     (t (logxor pkg-code-scramble sym-code)))))))
          ((stringp x)
           (fchecksum-string x))
          ((characterp x) ; just scramble using another primitive root
           (times-mod-m31 (char-code x) 619823821))
          ((rationalp x)
           (let* ((num-code (fchecksum-atom (numerator x)))
                  (den-code (fchecksum-natural (denominator x)))
                  (num-scramble
                   (times-mod-m31 num-code 111298397))
                  (den-scramble
                   (times-mod-m31 den-code 391892127)))
             (declare (type (signed-byte 32)
                            num-code den-code num-scramble den-scramble))
             (logxor num-scramble den-scramble)))
          ((complex-rationalp x)
           (let* ((imag-code (fchecksum-atom (imagpart x)))
                  (real-code (fchecksum-atom (realpart x)))
                  (imag-scramble
                   (times-mod-m31 imag-code 18783723))
                  (real-scramble
                   (times-mod-m31 real-code 981827319)))
             (declare (type (signed-byte 32)
                            imag-code real-code imag-scramble real-scramble))
             (logxor imag-scramble real-scramble)))
          (t
           (prog2$ (er hard 'fchecksum-atom "Bad atom, ~x0"
                       x)
                   0)))))

(defun fchecksum-obj (x)

; Finally, we just use the same idea to scramble cars and cdrs on conses.  To
; make this efficient on structure-shared objects, it ought to be memoized.  We
; do this explicitly in memoize-raw.lisp (for ACL2h).

; Warning: With #+hons, there could be performance problems if this is put into
; :logic mode without verifying guards.  That is because fchecksum-obj is
; memoized by running acl2h-init, and for memoization, we expect the raw Lisp
; function to be executed, but :ideal mode functions are run without ever
; slipping into raw Lisp.

; Note that we could make this partially tail-recursive by accumulating from
; the cdr, but this would ruin memoization.  If we find performance problems
; with non-hons versions, we could consider having two versions of
; fchecksum-obj, and passing state into check-sum-obj to decide which one to
; call depending on whether or not fchecksum-obj is memoized.

  (declare (xargs :guard t))
  (the (signed-byte 32)
    (if (atom x)
        (fchecksum-atom x)
      (let* ((car-code (fchecksum-obj (car x)))
             (cdr-code (fchecksum-obj (cdr x)))
             (car-scramble
              (times-mod-m31 car-code 627718124))
             (cdr-scramble
              (times-mod-m31 cdr-code 278917287)))
        (declare (type (signed-byte 32)
                       car-code cdr-code car-scramble cdr-scramble))
        (logxor car-scramble cdr-scramble)))))

#-acl2-loop-only
(declaim (notinline check-sum-obj)) ; see comment below for old code

(defun check-sum-obj (obj)
  (declare (xargs :guard t))
  (fchecksum-obj obj))

; ; To use old check-sum-obj code, but then add check-sum-obj to
; ; *PRIMITIVE-PROGRAM-FNS-WITH-RAW-CODE* if doing this for a build:
; (defun check-sum-obj (obj)
;   #-acl2-loop-only
;   (return-from check-sum-obj
;                (mv-let (val state)
;                        (old-check-sum-obj obj *the-live-state*)
;                        (declare (ignore state))
;                        val))
;   #+acl2-loop-only
;   (declare (ignore obj))
;   (er hard 'check-sum-obj "ran *1* code for check-sum-obj"))

; Here are some examples.
;
;  (fchecksum-obj 0)
;  (fchecksum-obj 19)
;  (fchecksum-obj 1892)
;  (fchecksum-obj "foo")
;  (fchecksum-obj "bfdkja")
;  (fchecksum-obj #\a)
;  (fchecksum-obj "a")
;  (fchecksum-obj #\b)
;  (fchecksum-obj #\c)
;  (fchecksum-obj 189)
;  (fchecksum-obj -189)
;  (fchecksum-obj -19189)
;  (fchecksum-obj -19283/188901)
;  (fchecksum-obj 19283/188901)
;  (fchecksum-obj 19283/2)
;  (fchecksum-obj 2/19283)
;  (fchecksum-obj 19283)
;  (fchecksum-obj #c(19283 198))
;  (fchecksum-obj #c(198 19283))
;  (fchecksum-obj #c(-19283/1238 198))
;
;  (fchecksum-obj 3)
;  (fchecksum-obj '(3 . nil))
;  (fchecksum-obj '(nil . 3))
;
;  (fchecksum-obj nil)
;  (fchecksum-obj '(nil))
;  (fchecksum-obj '(nil nil))
;  (fchecksum-obj '(nil nil nil))
;  (fchecksum-obj '(nil nil nil nil))
;
; ; And here are some additional comments.  If you want to generate more
; ; primitive roots, or verify that the ones we have picked are primitive roots,
; ; try this:
;
;  (include-book "arithmetic-3/floor-mod/mod-expt-fast" :dir :system)
;  (include-book "make-event/assert" :dir :system)
;
; ; Here we establish that the factors of M31-1 are 2, 3, 7, 11, 31, 151, and
; ; 331.
;
;  (assert! (equal (- #x7FFFFFFF 1)
;                  (* 2 3 3 7 11 31 151 331)))
;
; ;; And so the following is sufficient to establish that n is a primitive
; ;; root.
;
; (defund primitive-root-p (n)
;   (let* ((m31   #x7FFFFFFF)
;          (m31-1 (- m31 1)))
;     (and (not (equal (mod-expt-fast n (/ m31-1 2) m31) 1))
;          (not (equal (mod-expt-fast n (/ m31-1 3) m31) 1))
;          (not (equal (mod-expt-fast n (/ m31-1 7) m31) 1))
;          (not (equal (mod-expt-fast n (/ m31-1 11) m31) 1))
;          (not (equal (mod-expt-fast n (/ m31-1 31) m31) 1))
;          (not (equal (mod-expt-fast n (/ m31-1 151) m31) 1))
;          (not (equal (mod-expt-fast n (/ m31-1 331) m31) 1)))))
;
; ; And here are some primitive roots that we found.  There are lots of
; ; them.  If you want a new one, just pick a number and start incrementing
; ; or decrementing until it says T.
;
;  (primitive-root-p 506249751)
;  (primitive-root-p 392894102)
;  (primitive-root-p 938187814)
;  (primitive-root-p 718273893)
;  (primitive-root-p 619823821)
;  (primitive-root-p 283748912)
;  (primitive-root-p 111298397)
;  (primitive-root-p 391892127)
;  (primitive-root-p 18783723)
;  (primitive-root-p 981827319)
;
;  (primitive-root-p 627718124)
;  (primitive-root-p 278917287)
;
; ; At one point I [Jared] used this function to analyze different
; ; implementations of fchecksum-natural.  You might find it useful if you want
; ; to write an alternate implementation.  You want to produce a fast routine
; ; that doesn't have many collisions.
;
; (defun analyze-fchecksum-natural (n)
;   (let (table ones twos more)
;     ;; Table is a mapping from sums to the number of times they are hit.
;     (setq table (make-hash-table))
;     (loop for i from 1 to n do
;           (let ((sum (fchecksum-natural i)))
;             (setf (gethash sum table)
;                   (+ 1 (nfix (gethash sum table))))))
;     ;; Now we will walk the table and see how many sums are hit once,
;     ;; twice, or more often than that.
;     (setq ones 0)
;     (setq twos 0)
;     (setq more 0)
;     (maphash (lambda (key val)
;                (declare (ignore key))
;                (cond ((= val 1) (incf ones val))
;                      ((= val 2) (incf twos val))
;                      (t         (incf more val))))
;              table)
;     (format t "~a~%" (list ones twos more))
;     (format t "Unique mappings: ~5,2F%~%"
;             (* 100 (/ (coerce ones 'float) n)))
;     (format t "2-ary collisions: ~5,2F%~%"
;             (* 100 (/ (coerce twos 'float) n)))
;     (format t "3+-ary collisions: ~5,2F%~%"
;             (* 100 (/ (coerce more 'float) n)))))
;
;  (analyze-fchecksum-natural 1000)
;  (analyze-fchecksum-natural 10000)
;  (analyze-fchecksum-natural 100000)
;  (analyze-fchecksum-natural 1000000)
;  (analyze-fchecksum-natural 10000000)

; End of checksum code.

(defun read-file-iterate (channel acc state)
  (mv-let (eof obj state)
    (read-object channel state)
    (cond (eof
           (mv (reverse acc) state))
          (t (read-file-iterate channel (cons obj acc) state)))))

(defun read-file (name state)
  (mv-let (channel state)
    (open-input-channel name :object state)
    (cond (channel
           (mv-let (ans state)
             (read-file-iterate channel nil state)
             (pprogn (close-input-channel channel state)
                     (mv nil ans state))))
          (t (er soft 'read-file "No file found ~x0." name)))))

(defun formals (fn w)
  (declare (xargs :guard (and (symbolp fn)
                              (plist-worldp w))))
  (cond ((flambdap fn)
         (lambda-formals fn))
        (t (let ((temp (getprop fn 'formals t 'current-acl2-world w)))
             (cond ((eq temp t)
                    (er hard? 'formals
                        "Every function symbol is supposed to have a ~
                         'FORMALS property but ~x0 does not!"
                        fn))
                   (t temp))))))

(defun arity (fn w)
  (cond ((flambdap fn) (length (lambda-formals fn)))
        (t (let ((temp (getprop fn 'formals t 'current-acl2-world w)))
             (cond ((eq temp t) nil)
                   (t (length temp)))))))

(defun stobjs-out (fn w)

; Warning: keep this in sync with get-stobjs-out-for-declare-form.

; See the Essay on STOBJS-IN and STOBJS-OUT.

  (cond ((eq fn 'cons)
; We call this function on cons so often we optimize it.
         '(nil))
        ((member-eq fn '(if return-last))
         (er hard! 'stobjs-out
             "Implementation error: Attempted to find stobjs-out for ~x0."
             fn))
        (t (getprop fn 'stobjs-out '(nil) 'current-acl2-world w))))

; With stobjs-out defined, we can define user-defined-functions-table.

(defconst *user-defined-functions-table-keys*

; Although it would be very odd to add return-last to this list, we state here
; explicitly that it is illegal to do so, because user-defined-functions-table
; has a :guard that relies on this in order to avoid applying stobjs-out to
; return-last.

  '(untranslate untranslate-lst untranslate-preprocess))

(table user-defined-functions-table nil nil
       :guard
       (and (member-eq key *user-defined-functions-table-keys*)
            (symbolp val)
            (not (eq (getprop val 'formals t 'current-acl2-world world)
                     t))
            (all-nils (stobjs-out val world))))

(defrec def-body

; Use the 'recursivep property, not this :recursivep field, when referring to
; the original definition, as is necessary for verify-guards,
; verify-termination, and handling of *1* functions.

  ((nume
    hyp ; nil if there are no hypotheses
    .
    concl)
   .
   (recursivep formals rune . controller-alist))
  t)

(defun latest-body (fncall hyp concl)
  (if hyp
      (fcons-term* 'if hyp concl
                   (fcons-term* 'hide fncall))
    concl))

(defun def-body (fn wrld)
  (car (getprop fn 'def-bodies nil 'current-acl2-world wrld)))

(defun body (fn normalp w)

; The safe way to call this function is with normalp = nil, which yields the
; actual original body of fn.  The normalized body is provably equal to the
; unnormalized body, but that is not a strong enough property in some cases.
; Consider for example the following definition: (defun foo () (car 3)).  Then
; (body 'foo nil (w state)) is (CAR '3), so guard verification for foo will
; fail, as it should.  But (body 'foo t (w state)) is 'NIL, so we had better
; scan the unnormalized body when generating the guard conjecture rather than
; the normalized body.  Functional instantiation may also be problematic if
; constraints are gathered using the normalized body, although we do not yet
; have an example showing that this is critical.

; WARNING: If normalp is non-nil, then we are getting the most recent body
; installed by a :definition rule with non-nil :install-body value.  Be careful
; that this is really what is desired; and if so, be aware that we are not
; returning the corresponding def-body rune.

  (cond ((flambdap fn)
         (lambda-body fn))
        (normalp (let ((def-body (def-body fn w)))
                   (latest-body (fcons-term fn
                                            (access def-body def-body
                                                    :formals))
                                (access def-body def-body :hyp)
                                (access def-body def-body :concl))))
        (t (getprop fn 'unnormalized-body nil 'current-acl2-world w))))

(defun symbol-class (sym wrld)

; The symbol-class of a symbol is one of three keywords:

; :program                  - not defined within the logic
; :ideal                 - defined in the logic but not known to be CL compliant
; :common-lisp-compliant - defined in the logic and known to be compliant with
;                          Common Lisp

; Convention: We never print the symbol-classes to the user.  We would prefer
; the user not to think about these classes per se.  It encourages a certain
; confusion, we think, because users want everything to be
; common-lisp-compliant and start thinking of it as a mode, sort of like "super
; :logic" or something.  So we are keeping these names to ourselves by not
; using them in error messages and documentation.  Typically used English
; phrases are such and such is "compliant with Common Lisp" or "is not known to
; be compliant with Common Lisp."

; Historical Note: :Program function symbols were once called "red", :ideal
; symbols were once called "blue", and :common-lisp-compliant symbols were once
; called "gold."

; Before we describe the storage scheme, let us make a few observations.
; First, most function symbols have the :program symbol-class, because until
; ACL2 is admitted into the logic, the overwhelming majority of the function
; symbols will be system functions.  Second, all :logic function symbols have
; symbol-class :ideal or :common-lisp-compliant.  Third, this function,
; symbol-class, is most often applied to :logic function symbols, because most
; often we use it to sweep through the function symbols in a term before
; verify-guards.  Finally, theorem names are very rarely of interest here but
; they are always either :ideal or (very rarely) :common-lisp-compliant.

; Therefore, our storage scheme is that every :logic function will have a
; symbol-class property that is either :ideal or :common-lisp-compliant.  We
; will not store a symbol-class property for :program but just rely on the
; absence of the property (and the fact that the symbol is recognized as a
; function symbol) to default its symbol-class to :program.  Thus, system
; functions take no space but are slow to answer.  Finally, theorems will
; generally have no stored symbol-class (so it will default to :ideal for them)
; but when it is stored it will be :common-lisp-compliant.

; Note that the defun-mode of a symbol is actually determined by looking at its
; symbol-class.  We only store the symbol-class.  That is more often the
; property we need to look at.  But we believe it is simpler for the user to
; think in terms of :mode and :verify-guards.

  (declare (xargs :guard (and (symbolp sym)
                              (plist-worldp wrld))))
  (or (getprop sym 'symbol-class nil 'current-acl2-world wrld)
      (if (getprop sym 'theorem nil 'current-acl2-world wrld)
          :ideal
          :program)))

(defmacro fdefun-mode (fn wrld)

; Fn must be a symbol and a function-symbol of wrld.

  `(if (eq (symbol-class ,fn ,wrld) :program)
       :program
       :logic))

(defmacro programp (fn wrld)
  `(eq (symbol-class ,fn ,wrld) :program))

(defmacro logicalp (fn wrld)
  `(not (eq (symbol-class ,fn ,wrld) :program)))

(mutual-recursion

(defun program-termp (term wrld)
  (cond ((variablep term) nil)
        ((fquotep term) nil)
        ((flambdap (ffn-symb term))
         (or (program-termp (lambda-body (ffn-symb term)) wrld)
             (program-term-listp (fargs term) wrld)))
        ((programp (ffn-symb term) wrld) t)
        (t (program-term-listp (fargs term) wrld))))

(defun program-term-listp (lst wrld)
  (cond ((null lst) nil)
        (t (or (program-termp (car lst) wrld)
               (program-term-listp (cdr lst) wrld)))))
)

(defun defun-mode (name wrld)

; Only function symbols have defun-modes.  For all other kinds of names
; e.g., package names and macro names, the "defun-mode" is nil.

; Implementation Note:  We do not store the defun-mode of a symbol on the
; property list of the symbol.  We compute the defun-mode from the symbol-class.

  (cond ((and (symbolp name)
              (function-symbolp name wrld))
         (fdefun-mode name wrld))
        (t nil)))

; Rockwell Addition: Consider the guard conjectures for a stobj-using
; function.  Every accessor and updater application will generate the
; obligation to prove (stp st), where stp is the recognizer for the
; stobj st.  But this is guaranteed to be true for bodies that have
; been translated as defuns, because of the syntactic restrictions on
; stobjs.  So in this code we are concerned with optimizing these
; stobj recognizer expressions away, by replacing them with T.

(defun get-stobj-recognizer (stobj wrld)

; If stobj is a stobj name, return the name of its recognizer; else nil.  The
; value of the 'stobj property is always (*the-live-var* recognizer creator
; ...), for all user defined stobj names.  The value is '(*the-live-state*) for
; STATE and is nil for all other names.

  (cond ((eq stobj 'state)
         'state-p)
        (t (cadr (getprop stobj 'stobj nil 'current-acl2-world wrld)))))

(defun stobj-recognizer-terms (known-stobjs wrld)

; Given a list of stobjs, return the list of recognizer applications.
; E.g., given (STATE MY-ST) we return ((STATE-P STATE) (MY-STP MY-ST)).

  (cond ((null known-stobjs) nil)
        (t (cons (fcons-term* (get-stobj-recognizer (car known-stobjs) wrld)
                              (car known-stobjs))
                 (stobj-recognizer-terms (cdr known-stobjs) wrld)))))

(defun mcons-term-smart (fn args)

; The following function is guaranteed to create a term provably equal to (cons
; fn args).  If we find other optimizations to make here, we should feel free
; to do so.

  (if (and (eq fn 'if)
           (equal (car args) *t*))
      (cadr args)
    (cons-term fn args)))

(mutual-recursion

(defun optimize-stobj-recognizers1 (known-stobjs recog-terms term)
  (cond
   ((variablep term) term)
   ((fquotep term) term)
   ((flambda-applicationp term)

; We optimize the stobj recognizers in the body of the lambda.  We do
; not have to watch out of variable name changes, since if a stobj
; name is passed into a lambda it is passed into a local of the same
; name.  We need not optimize the body if no stobj name is used as a
; formal.  But we have to optimize the args in either case.

    (let ((formals (lambda-formals (ffn-symb term)))
          (body (lambda-body (ffn-symb term))))
      (cond
       ((intersectp-eq known-stobjs formals)
        (fcons-term
         (make-lambda formals
                      (optimize-stobj-recognizers1
                       known-stobjs
                       recog-terms
                       body))
         (optimize-stobj-recognizers1-lst known-stobjs
                                          recog-terms
                                          (fargs term))))
       (t (fcons-term (ffn-symb term)
                      (optimize-stobj-recognizers1-lst known-stobjs
                                                       recog-terms
                                                       (fargs term)))))))
   ((and (null (cdr (fargs term)))
         (member-equal term recog-terms))

; If the term is a recognizer call, e.g., (MY-STP MY-ST), we replace
; it by T.  The first conjunct above is just a quick test: If the term
; has 2 or more args, then don't bother to do the member-equal.  If
; the term has 1 or 0 (!) args we do.  We won't find it if it has 0
; args.

    *t*)
   (t (mcons-term-smart (ffn-symb term)
                        (optimize-stobj-recognizers1-lst known-stobjs
                                                         recog-terms
                                                         (fargs term))))))

(defun optimize-stobj-recognizers1-lst (known-stobjs recog-terms lst)
  (cond
   ((endp lst) nil)
   (t (cons (optimize-stobj-recognizers1 known-stobjs recog-terms (car lst))
            (optimize-stobj-recognizers1-lst known-stobjs
                                             recog-terms
                                             (cdr lst)))))))

(defun optimize-stobj-recognizers (known-stobjs term wrld)

; Term is a term.  We scan it and find every call of the form (st-p
; st) where st is a member of known-stobjs and st-p is the stobj
; recognizer function for st.  We replace each such call by T.  The
; idea is that we have simplified term under the assumption that each
; (st-p st) is non-nil.  This simplification preserves equivalence
; with term PROVIDED all stobj recognizers are Boolean valued!

  (cond
   ((null known-stobjs) term)
   (t (optimize-stobj-recognizers1
       known-stobjs
       (stobj-recognizer-terms known-stobjs wrld)
       term))))

; Rockwell Addition: The new flag, stobj-optp, determines whether the
; returned guard has had all the stobj recognizers optimized away.  Of
; course, whether you should call this with stobj-optp t or nil
; depends on the expression you're exploring: if it has been suitably
; translated, you can use t, else you must use nil.  Every call of
; guard (and all the functions that call those) has been changed to
; pass down this flag.  I won't mark every such place, but they'll
; show up in the compare-windows.

(defun guard (fn stobj-optp w)

; This function is just the standard way to obtain the guard of fn in
; world w.

; If stobj-optp is t, we optimize the returned term, simplifying it
; under the assumption that every stobj recognizer in it is true.  If
; fn traffics in stobjs, then it was translated under the stobj
; syntactic restrictions.  Let st be a known stobj for fn (i.e.,
; mentioned in its stobjs-in) and let st-p be the corresponding
; recognizer.  This function should only be called with stobj-optp = t
; if you know (st-p st) to be true in the context of that call.

; The documentation string below addresses the general notion of
; guards in ACL2, rather than explaining this function.

  (cond ((flambdap fn) *t*)
        ((or (not stobj-optp)
             (all-nils (stobjs-in fn w)) )
         (getprop fn 'guard *t* 'current-acl2-world w))
        (t

; If we have been told to optimize the stobj recognizers (stobj-optp =
; t) and there are stobjs among the arguments of fn, then fn was
; translated with the stobj syntactic restrictions enforced for those
; names.  That means we can optimize the guard of the function
; appropriately.

         (optimize-stobj-recognizers
          (collect-non-x 'nil (stobjs-in fn w))
          (or (getprop fn 'guard *t* 'current-acl2-world w)

; Once upon a time we found a guard of nil, and it took awhile to track down
; the source of the ensuing error.

              (illegal 'guard "Found a nil guard for ~x0."
                       (list (cons #\0 fn))))
          w))))

(defun guard-lst (fns stobj-optp w)
  (cond ((null fns) nil)
        (t (cons (guard (car fns) stobj-optp w)
                 (guard-lst (cdr fns) stobj-optp w)))))

(defmacro equivalence-relationp (fn w)

; See the Essay on Equivalence, Refinements, and Congruence-based
; Rewriting.

; (Note: At the moment, the fact that fn is an equivalence relation is
; encoded merely by existence of a non-nil 'coarsenings property.  No
; :equivalence rune explaining why fn is an equivalence relation is to
; be found there -- though such a rune does exist and is indeed found
; among the 'congruences of fn itself.  We do not track the use of
; equivalence relations, we just use them anonymously.  It would be
; good to track them and report them.  When we do that, read the Note
; on Tracking Equivalence Runes in subst-type-alist1.)

  `(let ((fn ,fn))

; While both equal and iff have non-nil coarsenings properties, we make
; special cases of them here because they are common and we wish to avoid
; the getprop.

     (or (eq fn 'equal)
         (eq fn 'iff)
         (and (not (flambdap fn))
              (getprop fn 'coarsenings nil 'current-acl2-world ,w)))))

(defun >=-len (x n)
  (declare (xargs :guard (and (integerp n) (<= 0 n))))
  (if (= n 0)
      t
      (if (atom x)
          nil
          (>=-len (cdr x) (1- n)))))

(defun all->=-len (lst n)
  (declare (xargs :guard (and (integerp n) (<= 0 n))))
  (if (atom lst)
      (eq lst nil)
      (and (>=-len (car lst) n)
           (all->=-len (cdr lst) n))))

(defun strip-cadrs (x)
  (declare (xargs :guard (all->=-len x 2)))
  (cond ((endp x) nil)
        (t (cons (cadar x) (strip-cadrs (cdr x))))))

; Rockwell Addition: Just moved from other-events.lisp

(defun strip-cddrs (x)
  (declare (xargs :guard (all->=-len x 2)))
  (cond ((endp x) nil)
        (t (cons (cddar x) (strip-cddrs (cdr x))))))

(defun global-set-lst (alist wrld)
  (cond ((null alist) wrld)
        (t (global-set-lst (cdr alist)
                           (global-set (caar alist)
                                       (cadar alist)
                                       wrld)))))

(defmacro cons-term1-body-mv2 ()
  `(let ((x (unquote (car args)))
         (y (unquote (cadr args))))
     (let ((evg (case fn
                  ,@*cons-term1-alist*
                  (if (kwote (if x y (unquote (caddr args)))))
                  (not (kwote (not x))))))
       (cond (evg (mv t evg))
             (t (mv nil form))))))

(defun cons-term1-mv2 (fn args form)
  (declare (xargs :guard (and (pseudo-term-listp args)
                              (quote-listp args))))
  (cons-term1-body-mv2))

(mutual-recursion

(defun sublis-var1 (alist form)
  (declare (xargs :guard (and (symbol-alistp alist)
                              (pseudo-term-listp (strip-cdrs alist))
                              (pseudo-termp form))))
  (cond ((variablep form)
         (let ((a (assoc-eq form alist)))
           (cond (a (mv (not (eq form (cdr a)))
                        (cdr a)))
                 (t (mv nil form)))))
        ((fquotep form)
         (mv nil form))
        (t (mv-let (changedp lst)
                   (sublis-var1-lst alist (fargs form))
                   (let ((fn (ffn-symb form)))
                     (cond (changedp (mv t (cons-term fn lst)))
                           ((and (symbolp fn) ; optimization
                                 (quote-listp lst))
                            (cons-term1-mv2 fn lst form))
                           (t (mv nil form))))))))

(defun sublis-var1-lst (alist l)
  (declare (xargs :guard (and (symbol-alistp alist)
                              (pseudo-term-listp (strip-cdrs alist))
                              (pseudo-term-listp l))))
  (cond ((endp l)
         (mv nil l))
        (t (mv-let (changedp1 term)
                   (sublis-var1 alist (car l))
                   (mv-let (changedp2 lst)
                           (sublis-var1-lst alist (cdr l))
                           (cond ((or changedp1 changedp2)
                                  (mv t (cons term lst)))
                                 (t (mv nil l))))))))
)

(defun sublis-var (alist form)

; Call this function with alist = nil to put form into quote-normal form so
; that for example if form is (cons '1 '2) then '(1 . 2) is returned.  The
; following two comments come from the nqthm version of this function.

;     In REWRITE-WITH-LEMMAS we use this function with the nil alist
;     to put form into quote normal form.  Do not optimize this
;     function for the nil alist.

;     This is the only function in the theorem prover that we
;     sometimes call with a "term" that is not in quote normal form.
;     However, even this function requires that form be at least a
;     pseudo-termp.

; We rely on quote-normal form for the return value, for example in calls of
; sublis-var in rewrite-with-lemma and in apply-top-hints-clause1.

  (declare (xargs :guard (and (symbol-alistp alist)
                              (pseudo-term-listp (strip-cdrs alist))
                              (pseudo-termp form))))
  (mv-let (changedp val)
          (sublis-var1 alist form)
          (declare (ignore changedp))
          val))

(defun sublis-var-lst (alist l)
  (declare (xargs :guard (and (symbol-alistp alist)
                              (pseudo-term-listp (strip-cdrs alist))
                              (pseudo-term-listp l))))
  (mv-let (changedp val)
          (sublis-var1-lst alist l)
          (declare (ignore changedp))
          val))

(defun subcor-var1 (vars terms var)
  (declare (xargs :guard (and (symbol-listp vars)
                              (pseudo-term-listp terms)
                              (equal (length vars) (length terms))
                              (variablep var))))
  (cond ((endp vars) var)
        ((eq var (car vars)) (car terms))
        (t (subcor-var1 (cdr vars) (cdr terms) var))))

(mutual-recursion

(defun subcor-var (vars terms form)

; "Subcor" stands for "substitute corresponding elements".  Vars and terms are
; in 1:1 correspondence, and we substitute terms for corresponding vars into
; form.  This function was called sub-pair-var in nqthm.

  (declare (xargs :guard (and (symbol-listp vars)
                              (pseudo-term-listp terms)
                              (equal (length vars) (length terms))
                              (pseudo-termp form))))
  (cond ((variablep form)
         (subcor-var1 vars terms form))
        ((fquotep form) form)
        (t (cons-term (ffn-symb form)
                      (subcor-var-lst vars terms (fargs form))))))

(defun subcor-var-lst (vars terms forms)
  (declare (xargs :guard (and (symbol-listp vars)
                              (pseudo-term-listp terms)
                              (equal (length vars) (length terms))
                              (pseudo-term-listp forms))))
  (cond ((endp forms) nil)
        (t (cons (subcor-var vars terms (car forms))
                 (subcor-var-lst vars terms (cdr forms))))))

)

; We now develop the code to take a translated term and "untranslate"
; it into something more pleasant to read.

(defun car-cdr-nest1 (term ad-lst n)
  (cond ((or (int= n 4)
             (variablep term)
             (fquotep term)
             (and (not (eq (ffn-symb term) 'car))
                  (not (eq (ffn-symb term) 'cdr))))
         (mv ad-lst term))
        (t (car-cdr-nest1 (fargn term 1)
                          (cons (if (eq (ffn-symb term) 'car)
                                    #\A
                                  #\D)
                                ad-lst)
                          (1+ n)))))

(defun car-cdr-nest (term)
  (cond ((variablep term) (mv nil term))
        ((fquotep term) (mv nil term))
        ((or (eq (ffn-symb term) 'car)
             (eq (ffn-symb term) 'cdr))
         (mv-let (ad-lst guts)
           (car-cdr-nest1 (fargn term 1) nil 1)
           (cond
            (ad-lst
             (mv
              (intern
               (coerce
                (cons #\C
                      (cons (if (eq (ffn-symb term) 'car)
                                #\A
                              #\D)
                            (revappend ad-lst '(#\R))))
                'string)
               "ACL2")
              guts))
            (t (mv nil term)))))
        (t (mv nil nil))))

(defun collect-non-trivial-bindings (vars vals)
  (cond ((null vars) nil)
        ((eq (car vars) (car vals))
         (collect-non-trivial-bindings (cdr vars) (cdr vals)))
        (t (cons (list (car vars) (car vals))
                 (collect-non-trivial-bindings (cdr vars) (cdr vals))))))

(defun untranslate-and (p q iff-flg)

; The following theorem illustrates the various cases:
; (thm (and (equal (and t q) q)
;           (iff (and p t) p)
;           (equal (and p (and q1 q2)) (and p q1 q2))))

; Warning: Keep this in sync with and-addr.

  (cond ((eq p t) q)
        ((and iff-flg (eq q t)) p)
        ((and (consp q)
              (eq (car q) 'and))
         (cons 'and (cons p (cdr q))))
        (t (list 'and p q))))

(defun untranslate-or (p q)

; The following theorem illustrates the various cases:
; (thm (equal (or p (or q1 q2)) (or p q1 q2))))

  (cond ((and (consp q)
              (eq (car q) 'or))
         (cons 'or (cons p (cdr q))))
        (t (list 'or p q))))

(defun case-length (key term)

; Key is either nil or a variablep symbol.  Term is a term.  We are
; imagining printing term as a case on key.  How long is the case
; statement?  Note that every term can be printed as (case key
; (otherwise term)) -- a case of length 1.  If key is nil we choose it
; towards extending the case-length.

  (case-match term
              (('if ('equal key1 ('quote val)) & y)
               (cond ((and (if (null key)
                               (variablep key1)
                             (eq key key1))
                           (eqlablep val))
                      (1+ (case-length key1 y)))
                     (t 1)))
              (('if ('eql key1 ('quote val)) & y)
               (cond ((and (if (null key)
                               (variablep key1)
                             (eq key key1))
                           (eqlablep val))
                      (1+ (case-length key1 y)))
                     (t 1)))
              (('if ('member key1 ('quote val)) & y)
               (cond ((and (if (null key)
                               (variablep key1)
                             (eq key key1))
                           (eqlable-listp val))
                      (1+ (case-length key1 y)))
                     (t 1)))
              (& 1)))

; And we do a similar thing for cond...

(defun cond-length (term)
  (case-match term
              (('if & & z) (1+ (cond-length z)))
              (& 1)))

; In general the following list should be set to contain all the boot-strap
; functions that have boolean type set.

(defconst *untranslate-boolean-primitives*
  '(equal))

(defun right-associated-args (fn term)

; Fn is a function symbol of two arguments.  Term is a call of fn.
; E.g., fn might be 'BINARY-+ and term might be '(BINARY-+ A (BINARY-+
; B C)).  We return the list of arguments in the right-associated fn
; nest, e.g., '(A B C).

  (let ((arg2 (fargn term 2)))
    (cond ((and (nvariablep arg2)
                (not (fquotep arg2))
                (eq fn (ffn-symb arg2)))
           (cons (fargn term 1) (right-associated-args fn arg2)))
          (t (fargs term)))))

(defun dumb-negate-lit (term)
  (declare (xargs :guard (pseudo-termp term)))
  (cond ((variablep term)
         (fcons-term* 'not term))
        ((fquotep term)
         (cond ((equal term *nil*) *t*)
               (t *nil*)))
        ((eq (ffn-symb term) 'not)
         (fargn term 1))
        ((and (eq (ffn-symb term) 'equal)
              (or (equal (fargn term 2) *nil*)
                  (equal (fargn term 1) *nil*)))
         (if (equal (fargn term 2) *nil*)
             (fargn term 1)
             (fargn term 2)))
        (t (fcons-term* 'not term))))

(defun dumb-negate-lit-lst (lst)
  (cond ((endp lst) nil)
        (t (cons (dumb-negate-lit (car lst))
                 (dumb-negate-lit-lst (cdr lst))))))

(mutual-recursion

(defun term-stobjs-out-alist (vars args alist wrld)
  (if (endp vars)
      nil
    (let ((st (term-stobjs-out (car args) alist wrld))
          (rest (term-stobjs-out-alist (cdr vars) (cdr args) alist wrld)))
      (if (and st (symbolp st))
          (acons (car vars) st rest)
        rest))))

(defun term-stobjs-out (term alist wrld)

; Warning: This function currently has heuristic application only.  We need to
; think harder about it if we are to rely on it for soundness.

  (cond
   ((variablep term)
    (or (cdr (assoc term alist))
        (and (getprop term 'stobj nil 'current-acl2-world wrld)
             term)))
   ((fquotep term)
    nil)
   ((eq (ffn-symb term) 'return-last)
    (term-stobjs-out (car (last (fargs term))) alist wrld))
   (t (let ((fn (ffn-symb term)))
        (cond
         ((member-eq fn '(nth mv-nth))
          (let* ((arg1 (fargn term 1))
                 (n (and (quotep arg1) (cadr arg1))))
            (and (integerp n)
                 (<= 0 n)
                 (let ((term-stobjs-out
                        (term-stobjs-out (fargn term 2) alist wrld)))
                   (and (consp term-stobjs-out)
                        (nth n term-stobjs-out))))))
         ((eq fn 'update-nth)
          (term-stobjs-out (fargn term 3) alist wrld))
         ((flambdap fn) ; (fn args) = ((lambda vars body) args)
          (let ((vars (lambda-formals fn))
                (body (lambda-body fn)))
            (term-stobjs-out body
                             (term-stobjs-out-alist vars (fargs term) alist wrld)
                             wrld)))
         ((eq fn 'if)
          (or (term-stobjs-out (fargn term 2) alist wrld)
              (term-stobjs-out (fargn term 3) alist wrld)))
         (t
          (let ((lst (stobjs-out fn wrld)))
            (cond ((and (consp lst) (null (cdr lst)))
                   (car lst))
                  (t lst)))))))))
)

(defun accessor-root (n term wrld)

; When term is a stobj name, say st, ac is the accessor function for st defined
; to return (nth n st), then untranslate maps (nth n st) to (nth *ac* st).
; The truth is that the 'accessor-names property of st is used to carry this
; out.  Update-nth gets similar consideration.

; But what about (nth 0 (run st n)), where run returns a stobj st?  Presumably
; we would like to print that as (nth *b* (run st n)) where b is the 0th field
; accessor function for st.  We would also like to handle terms such as (nth 1
; (mv-nth 3 (run st n))).  These more general cases are likely to be important
; to making stobj proofs palatable.  There is yet another consideration, which
; is that during proofs, the user may use variable names other than stobj names
; to refer to stobjs.  For example, there may be a theorem of the form
; (... st st0 ...), which could generate a term (nth n st0) during a proof that
; the user would prefer to see printed as (nth *b* st0).

; The present function returns the field name to be returned in place of n when
; untranslating (nth n term) or (update-nth n val term).  Wrld is, of course,
; an ACL2 world.

  (let ((st (term-stobjs-out term
                             (table-alist 'nth-aliases-table wrld)
                             wrld)))
    (and st
         (symbolp st)
         (let ((accessor-names
                (getprop st 'accessor-names nil 'current-acl2-world wrld)))
           (and accessor-names
                (< n (car (dimensions st accessor-names)))
                (aref1 st accessor-names n))))))

; We define progn! here so that it is available before its call in redef+.  But
; first we define observe-raw-mode-setting, a call of which is laid down by the
; use of f-put-global on 'acl2-raw-mode-p in the definition of progn!.

#-acl2-loop-only
(defun observe-raw-mode-setting (v state)

; We are about to set state global 'acl2-raw-mode-p to v.  We go through some
; lengths here to maintain the values of state globals
; 'raw-include-book-dir-alist and 'raw-include-book-dir!-alist, and warn when
; the value of either of these variables is discarded as we leave raw mode.  We
; are thus violating the semantics of put-global, by sometimes setting these
; two variables when only 'acl2-raw-mode-p is to be set -- but all bets are off
; when using raw mode, so this violation is tolerable.

  (let ((old-raw-mode (f-get-global 'acl2-raw-mode-p state))
        (old-raw-include-book-dir-alist
         (f-get-global 'raw-include-book-dir-alist state))
        (old-raw-include-book-dir!-alist
         (f-get-global 'raw-include-book-dir!-alist state))
        (ctx 'observe-raw-mode-setting))
    (cond
     ((or (iff v old-raw-mode)

; If we are executing a raw-Lisp include-book on behalf of include-book-fn,
; then a change in the status of raw mode is not important, as we will continue
; to maintain and use the values of state globals 'raw-include-book-dir-alist
; and 'raw-include-book-dir!-alist to compute the value of function
; include-book-dir.  The former state global is bound by state-global-let* in
; load-compiled-book, which in turn is called by include-book under
; include-book-fn.  The latter state global is set to an alist value (i.e., not
; :ignore) in include-book-raw-top, which in turn is called when doing early
; loads of compiled files by include-book-top, under include-book-fn, under
; include-book.

          *load-compiled-stack*)
      state)
     ((eq (not old-raw-mode)
          (raw-include-book-dir-p state))

; Clearly the two arguments of iff can't both be nil, since the value of
; 'raw-include-book-dir-alist is not ignored (it is never :ignore) in raw-mode.
; Can they both be t?  Assuming old-raw-mode is nil, then since (iff v
; old-raw-mode) is false, we are about to go into raw mode.  Also, since we are
; not in the previous case, we are not currently under include-book-fn.  But
; since we are currently not in raw mode and not under include-book-fn, we
; expect old-raw-include-book-dir-alist to be :ignore, as per the Essay on
; Include-book-dir-alist: "We maintain the invariant that :ignore is the value
; [of 'include-book-dir-alist] except when in raw-mode or during evaluation of
; include-book-fn."

      (prog2$ (er hard! ctx
                  "Implementation error: Transitioning from ~x0 = ~x1 and yet ~
                   the value of state global variable ~x2 is ~x3!  ~
                   Implementors should see the comment just above this ~
                   message in observe-raw-mode-setting."
                  'acl2-raw-mode-p
                  old-raw-mode
                  'raw-include-book-dir-alist
                  old-raw-include-book-dir-alist)
              state))
     (t
      (let* ((wrld (w state))
             (old-table-include-book-dir-alist
              (cdr (assoc-eq :include-book-dir-alist
                             (table-alist 'acl2-defaults-table wrld))))
             (old-table-include-book-dir!-alist
              (table-alist 'include-book-dir!-table wrld)))
        (pprogn
         (cond
          ((and
            old-raw-mode

; The warning below is probably irrelevant for a context such that
; acl2-defaults-table will ultimately be discarded, because even without
; raw-mode we will be discarding include-book-dir-alist changes.

            (not (acl2-defaults-table-local-ctx-p state))
            (or (not (equal old-raw-include-book-dir-alist
                            old-table-include-book-dir-alist))
                (not (equal old-raw-include-book-dir!-alist
                            old-table-include-book-dir!-alist))))
           (warning$ ctx "Raw-mode"
                     "The set of legal values for the :DIR argument of ~
                      include-book and ld appears to have changed when ~v0 ~
                      was executed in raw-mode.  Changes are being discarded ~
                      as we exit raw-mode."
                     (append
                      (and (not (equal old-table-include-book-dir-alist
                                       old-raw-include-book-dir-alist))
                           '(add-include-book-dir
                             delete-include-book-dir))
                      (and (not (equal old-table-include-book-dir!-alist
                                       old-raw-include-book-dir!-alist))
                           '(add-include-book-dir!
                             delete-include-book-dir!)))))
          (t state))
         (f-put-global 'raw-include-book-dir-alist
                       (cond (old-raw-mode

; We are leaving raw-mode and are not under include-book-fn.

                              :ignore)
                             (t old-table-include-book-dir-alist))
                       state)
         (f-put-global 'raw-include-book-dir!-alist
                       (cond (old-raw-mode

; We are leaving raw-mode and are not under include-book-fn.

                              :ignore)
                             (t old-table-include-book-dir!-alist))
                       state)))))))

#+acl2-loop-only
(defmacro progn! (&rest r)
  (declare (xargs :guard (or (not (symbolp (car r)))
                             (eq (car r) :state-global-bindings))))
  (cond
   ((and (consp r)
         (eq (car r) :state-global-bindings))
    `(state-global-let* ,(cadr r)
                        (progn!-fn ',(cddr r) ',(cadr r) state)))
    (t `(progn!-fn ',r nil state))))

#-acl2-loop-only
(defmacro progn! (&rest r)
  (let ((sym (gensym)))
    `(let ((state *the-live-state*)
           (,sym (f-get-global 'acl2-raw-mode-p *the-live-state*)))
       (declare (ignorable state))
       ,@(cond ((eq (car r) :state-global-bindings)
                (cddr r))
               (t r))

; Notice that we don't need to use state-global-let* to protect against the
; possibility that the resetting of acl2-raw-mode-p never gets executed below.
; There are two reasons.  First, ACL2's unwind protection mechanism doesn't
; work except inside the ACL2 loop, and although it may be that we always
; execute progn! forms from (ultimately) inside the ACL2 loop, it is preferable
; not to rely on that assumption.  The other reason is that we assume that
; there are no errors during the execution of r in raw Lisp, since presumably
; the progn! form was already admitted in the loop.  There are flaws in this
; assumption, of course: the user may abort or may be submitting the progn! in
; raw mode (in which case progn!-fn was not executed first).  So we may want to
; revisit the resetting of acl2-raw-mode-p, but in that case we need to
; consider whether we need our solution to work outside the ACL2 loop, and if
; so, then whether it actually does work.

       (f-put-global 'acl2-raw-mode-p ,sym state)
       (value nil))))

; The LD Specials

; The function LD will "bind" some state globals in the sense that it will
; smash their global values and then restore the old values upon completion.
; These state globals are called "LD specials".  The LD read-eval-print loop
; will reference these globals.  The user is permitted to set these globals
; with commands executed in LD -- with the understanding that the values are
; lost when LD is exited and the pop occurs.

; To make it easy to reference them and to ensure that they are set to legal
; values, we will define access and update functions for them.  We define the
; functions here rather than in ld.lisp so that we may use them freely in our
; code.

(defun ld-redefinition-action (state)
  (f-get-global 'ld-redefinition-action state))

(defun chk-ld-redefinition-action (val ctx state)
  (cond ((or (null val)
             (and (consp val)
                  (member-eq (car val) '(:query :warn :doit :warn! :doit!))
                  (member-eq (cdr val) '(:erase :overwrite))))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-redefinition-action val))))

(defun set-ld-redefinition-action (val state)
  (er-progn
   (chk-ld-redefinition-action val 'set-ld-redefinition-action state)
   (pprogn
    (f-put-global 'ld-redefinition-action val state)
    (value val))))

(defmacro redef nil
 '(set-ld-redefinition-action '(:query . :overwrite) state))

(defmacro redef! nil
 '(set-ld-redefinition-action '(:warn! . :overwrite) state))

(defmacro redef+ nil

; WARNING: Keep this in sync with redef-.

  #-acl2-loop-only
  nil
  #+acl2-loop-only
  `(with-output
    :off (summary event)
    (progn
      (defttag :redef+)
      (progn!
       (set-ld-redefinition-action '(:warn! . :overwrite)
                                   state)
       (program)
       (set-temp-touchable-vars t state)
       (set-temp-touchable-fns t state)
       (f-put-global 'redundant-with-raw-code-okp t state)
       (set-state-ok t)))))

(defmacro redef- nil

; WARNING: Keep this in sync with redef+.

  #-acl2-loop-only
  nil
  #+acl2-loop-only
  `(with-output
    :off (summary event)
    (progn
      (redef+) ; to allow forms below
      (progn! (f-put-global 'redundant-with-raw-code-okp nil state)
              (set-temp-touchable-vars nil state)
              (set-temp-touchable-fns nil state)
              (defttag nil)
              (logic)
              (set-ld-redefinition-action nil state)
              (set-state-ok nil)))))

(defun chk-current-package (val ctx state)
  (cond ((find-non-hidden-package-entry val (known-package-alist state))
         (value nil))
        (t (er soft ctx *ld-special-error* 'current-package val))))

(defun set-current-package (val state)

; This function is equivalent to in-package-fn except for the
; error message generated.

  (er-progn
   (chk-current-package val 'set-current-package state)
   (pprogn
    (f-put-global 'current-package val state)
    (value val))))

(defun standard-oi (state)
  (f-get-global 'standard-oi state))

(defun read-standard-oi (state)

; We let LD take a true-listp as the "input file" and so we here implement
; the generalized version of (read-object (standard-oi state) state).

  (let ((standard-oi (standard-oi state)))
    (cond ((consp standard-oi)
           (let ((state (f-put-global 'standard-oi (cdr standard-oi) state)))
             (mv nil (car standard-oi) state)))
          ((null standard-oi)
           (mv t nil state))
          (t (read-object standard-oi state)))))

(defun chk-standard-oi (val ctx state)
  (cond
   ((and (symbolp val)
         (open-input-channel-p val :object state))
    (value nil))
   ((true-listp val)
    (value nil))
   ((and (consp val)
         (symbolp (cdr (last val)))
         (open-input-channel-p (cdr (last val)) :object state))
    (value nil))
   (t (er soft ctx *ld-special-error* 'standard-oi val))))

(defun set-standard-oi (val state)
  (er-progn (chk-standard-oi val 'set-standard-oi state)
            (pprogn
             (f-put-global 'standard-oi val state)
             (value val))))

(defun standard-co (state)
  (f-get-global 'standard-co state))

(defun chk-standard-co (val ctx state)
  (cond
   ((and (symbolp val)
         (open-output-channel-p val :character state))
    (value nil))
   (t (er soft ctx *ld-special-error* 'standard-co val))))

(defun set-standard-co (val state)
  (er-progn
   (chk-standard-co val 'set-standard-co state)
   (pprogn
    (f-put-global 'standard-co val state)
    (value val))))

(defun proofs-co (state)
  (f-get-global 'proofs-co state))

(defun chk-proofs-co (val ctx state)
  (cond
   ((and (symbolp val)
         (open-output-channel-p val :character state))
    (value nil))
   (t (er soft ctx *ld-special-error* 'proofs-co val))))

(defun set-proofs-co (val state)
  (er-progn
   (chk-proofs-co val 'set-proofs-co state)
   (pprogn
    (f-put-global 'proofs-co val state)
    (value val))))

(defun ld-prompt (state)
  (f-get-global 'ld-prompt state))

(defun chk-ld-prompt (val ctx state)
  (cond ((or (null val)
             (eq val t)
             (let ((wrld (w state)))
               (and (symbolp val)
                    (equal (arity val wrld) 2)
                    (equal (stobjs-in val wrld) '(nil state))
                    (equal (stobjs-out val wrld) '(nil state)))))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-prompt val))))

(defun set-ld-prompt (val state)
  (er-progn
   (chk-ld-prompt val 'set-ld-prompt state)
   (pprogn
    (f-put-global 'ld-prompt val state)
    (value val))))

(defun ld-keyword-aliases (state)
  (table-alist 'ld-keyword-aliases (w state)))

(defun ld-keyword-aliasesp (key val wrld)
  (and (keywordp key)
       (true-listp val)
       (int= (length val) 2)
       (let ((n (car val))
             (fn (cadr val)))
         (and (natp n)
              (cond
               ((and (symbolp fn)
                     (function-symbolp fn wrld))
                (equal (arity fn wrld) n))
               ((and (symbolp fn)
                     (getprop fn 'macro-body nil
                              'current-acl2-world wrld))
                t)
               (t (and (true-listp fn)
                       (>= (length fn) 3)
                       (<= (length fn) 4)
                       (eq (car fn) 'lambda)
                       (arglistp (cadr fn))
                       (int= (length (cadr fn)) n))))))))

(table ld-keyword-aliases nil nil
       :guard
       (ld-keyword-aliasesp key val world))

#+acl2-loop-only
(defmacro add-ld-keyword-alias! (key val)
  `(state-global-let*
    ((inhibit-output-lst (list* 'summary 'event (@ inhibit-output-lst))))
    (progn (table ld-keyword-aliases ,key ,val)
           (table ld-keyword-aliases))))

#-acl2-loop-only
(defmacro add-ld-keyword-alias! (key val)
  (declare (ignore key val))
  nil)

(defmacro add-ld-keyword-alias (key val)
  `(local (add-ld-keyword-alias! ,key ,val)))

#+acl2-loop-only
(defmacro set-ld-keyword-aliases! (alist)
  `(state-global-let*
    ((inhibit-output-lst (list* 'summary 'event (@ inhibit-output-lst))))
    (progn (table ld-keyword-aliases nil ',alist :clear)
           (table ld-keyword-aliases))))

#-acl2-loop-only
(defmacro set-ld-keyword-aliases! (alist)
  (declare (ignore alist))
  nil)

(defmacro set-ld-keyword-aliases (alist &optional state)

; We add state (optionally) just for backwards compatibility through
; Version_6.2.  We might eliminate it after Version_6.3.

  (declare (ignore state))
  `(local (set-ld-keyword-aliases! ,alist)))

(defun ld-missing-input-ok (state)
  (f-get-global 'ld-missing-input-ok state))

(defun msgp (x)
  (declare (xargs :guard t))
  (or (stringp x)
      (and (true-listp x)
           (stringp (car x)))))

(defun chk-ld-missing-input-ok (val ctx state)
  (cond ((or (member-eq val '(t nil :warn))
             (msgp val) ; admittedly, a weak check
             )
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-missing-input-ok val))))

(defun set-ld-missing-input-ok (val state)
  (er-progn
   (chk-ld-missing-input-ok val 'set-ld-missing-input-ok state)
   (pprogn
    (f-put-global 'ld-missing-input-ok val state)
    (value val))))

(defun ld-pre-eval-filter (state)
  (f-get-global 'ld-pre-eval-filter state))

(defun new-namep (name wrld)

; We determine if name has properties on world wrld.  Once upon a time
; this was equivalent to just (not (assoc-eq name wrld)).  However, we
; have decided to ignore certain properties:
; * 'global-value - names with this property are just global variables
;                   in our code; we permit the user to define functions
;                   with those names.
; * 'table-alist - names with this property are being used as tables
; * 'table-guard - names with this property are being used as tables

; WARNING: If this list of properties is changed, change renew-name/erase.

; Additionally, if name has a non-nil 'redefined property name is treated as
; new if all of its other properties are as set by renew-name/erase or
; renew-name/overwrite, as appropriate.  The 'redefined property is set by
; renew-name to be (renewal-mode .  old-sig) where renewal-mode is :erase,
; :overwrite, or :reclassifying-overwrite.

  (let ((redefined (getprop name 'redefined nil 'current-acl2-world wrld)))
    (cond
     ((and (consp redefined)
           (eq (car redefined) :erase))

; If we erased the properties of name and they are still erased, then we
; will find no non-nil properties except for those left by
; renew-name/erase and renew-name.

      (not (has-propsp name
                       '(REDEFINED
                         GLOBAL-VALUE
                         TABLE-ALIST
                         TABLE-GUARD)
                       'current-acl2-world
                       wrld
                       nil)))
     ((and (consp redefined)
           (or (eq (car redefined) :overwrite)
               (eq (car redefined) :reclassifying-overwrite)))

; We make a check analogous to that for erasure, allowing arbitrary non-nil
; values on all the properties untouched by renew-name/overwrite and insisting
; that all the properties erased by that function are still gone.  Technically
; we should confirm that the lemmas property has been cleansed of all
; introductory rules, but in fact we allow it to have an arbitrary non-nil
; value.  This is correct because if 'formals is gone then we cleansed 'lemmas
; and nothing could have been put back there since name is not yet a function
; symbol again.

      (not (has-propsp name
                       '(REDEFINED

                         LEMMAS

                         GLOBAL-VALUE
                         LABEL
                         LINEAR-LEMMAS
                         FORWARD-CHAINING-RULES
                         ELIMINATE-DESTRUCTORS-RULE
                         COARSENINGS
                         CONGRUENCES
                         PEQUIVS
                         INDUCTION-RULES
                         THEOREM
                         UNTRANSLATED-THEOREM
                         CLASSES
                         CONST
                         THEORY
                         TABLE-GUARD
                         TABLE-ALIST
                         MACRO-BODY
                         MACRO-ARGS
                         PREDEFINED
                         TAU-PAIR
                         POS-IMPLICANTS
                         NEG-IMPLICANTS
                         UNEVALABLE-BUT-KNOWN
                         SIGNATURE-RULES-FORM-1
                         SIGNATURE-RULES-FORM-2
                         BIG-SWITCH
                         TAU-BOUNDERS-FORM-1
                         TAU-BOUNDERS-FORM-2
                         )
                       'current-acl2-world
                       wrld
                       nil)))
     (t (not (has-propsp name
                         '(GLOBAL-VALUE
                           TABLE-ALIST
                           TABLE-GUARD)
                         'current-acl2-world
                         wrld
                         nil))))))

(defun chk-ld-pre-eval-filter (val ctx state)
  (cond ((or (member-eq val '(:all :query))
             (and (symbolp val)
                  (not (keywordp val))
                  (not (equal (symbol-package-name val)
                              *main-lisp-package-name*))
                  (new-namep val (w state))))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-pre-eval-filter val))))

(defun set-ld-pre-eval-filter (val state)
  (er-progn
   (chk-ld-pre-eval-filter val 'set-ld-pre-eval-filter state)
   (pprogn
    (f-put-global 'ld-pre-eval-filter val state)
    (value val))))

(defun ld-pre-eval-print (state)
  (f-get-global 'ld-pre-eval-print state))

(defun chk-ld-pre-eval-print (val ctx state)
  (cond ((member-eq val '(nil t :never))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-pre-eval-print val))))

(defun set-ld-pre-eval-print (val state)
  (er-progn
   (chk-ld-pre-eval-print val 'set-ld-pre-eval-print state)
   (pprogn
    (f-put-global 'ld-pre-eval-print val state)
    (value val))))

(defun ld-post-eval-print (state)
  (f-get-global 'ld-post-eval-print state))

(defun chk-ld-post-eval-print (val ctx state)
  (cond ((member-eq val '(nil t :command-conventions))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-post-eval-print val))))

(defun set-ld-post-eval-print (val state)
  (er-progn
   (chk-ld-post-eval-print val 'set-ld-post-eval-print state)
   (pprogn
    (f-put-global 'ld-post-eval-print val state)
    (value val))))

(defun ld-error-triples (state)
  (f-get-global 'ld-error-triples state))

(defun chk-ld-error-triples (val ctx state)
  (cond ((member-eq val '(nil t))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-error-triples val))))

(defun set-ld-error-triples (val state)
  (er-progn
   (chk-ld-error-triples val 'set-ld-error-triples state)
   (pprogn
    (f-put-global 'ld-error-triples val state)
    (value val))))

(defun ld-error-action (state)
  (f-get-global 'ld-error-action state))

(defun chk-ld-error-action (val ctx state)
  (cond ((member-eq val '(:continue :return :return! :error))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-error-action val))))

(defun set-ld-error-action (val state)
  (er-progn
   (chk-ld-error-action val 'set-ld-error-action state)
   (pprogn
    (f-put-global 'ld-error-action val state)
    (value val))))

(defun ld-query-control-alist (state)
  (f-get-global 'ld-query-control-alist state))

(defun ld-query-control-alistp (val)
  (cond ((atom val) (or (eq val nil)
                        (eq val t)))
        ((and (consp (car val))
              (symbolp (caar val))
              (or (eq (cdar val) nil)
                  (eq (cdar val) t)
                  (keywordp (cdar val))
                  (and (consp (cdar val))
                       (keywordp (cadar val))
                       (null (cddar val)))))
         (ld-query-control-alistp (cdr val)))
        (t nil)))

(defun cdr-assoc-query-id (id alist)
  (cond ((atom alist) alist)
        ((eq id (caar alist)) (cdar alist))
        (t (cdr-assoc-query-id id (cdr alist)))))

(defun chk-ld-query-control-alist (val ctx state)
  (cond
   ((ld-query-control-alistp val)
    (value nil))
   (t (er soft ctx *ld-special-error* 'ld-query-control-alist val))))

(defun set-ld-query-control-alist (val state)
  (er-progn
   (chk-ld-query-control-alist val 'set-ld-query-control-alist state)
   (pprogn
    (f-put-global 'ld-query-control-alist val state)
    (value val))))

(defun ld-verbose (state)
  (f-get-global 'ld-verbose state))

(defun chk-ld-verbose (val ctx state)
  (cond ((or (stringp val)
             (and (consp val)
                  (stringp (car val))))
         (value nil))
        ((member-eq val '(nil t))
         (value nil))
        (t (er soft ctx *ld-special-error* 'ld-verbose val))))

(defun set-ld-verbose (val state)
  (er-progn
   (chk-ld-verbose val 'set-ld-verbose state)
   (pprogn
    (f-put-global 'ld-verbose val state)
    (value val))))

(defconst *nqthm-to-acl2-primitives*

; Keep this list in sync with documentation for nqthm-to-acl2.

  '((ADD1 1+)
    (ADD-TO-SET ADD-TO-SET-EQUAL ADD-TO-SET-EQ)
    (AND AND)
    (APPEND APPEND BINARY-APPEND)
    (APPLY-SUBR .   "Doesn't correspond to anything in ACL2, really.
                     See the documentation for DEFEVALUATOR and META.")
    (APPLY$ .       "See the documentation for DEFEVALUATOR and META.")
    (ASSOC ASSOC-EQUAL ASSOC ASSOC-EQ)
    (BODY .         "See the documentation for DEFEVALUATOR and META.")
    (CAR CAR)
    (CDR CDR)
    (CONS CONS)
    (COUNT ACL2-COUNT)
    (DIFFERENCE -)
    (EQUAL EQUAL EQ EQL =)
    (EVAL$ .        "See the documentation for DEFEVALUATOR and META.")
    (FALSE .        "Nqthm's F corresponds to the ACL2 symbol NIL.")
    (FALSEP NOT NULL)
    ;;(FIX)
    ;;(FIX-COST)
    ;;(FOR)
    (FORMALS .      "See the documentation for DEFEVALUATOR and META.")
    (GEQ >=)
    (GREATERP >)
    (IDENTITY IDENTITY)
    (IF IF)
    (IFF IFF)
    (IMPLIES IMPLIES)
    (LEQ <=)
    (LESSP <)
    (LISTP CONSP)
    (LITATOM SYMBOLP)
    (MAX MAX)
    (MEMBER MEMBER-EQUAL MEMBER MEMBER-EQ)
    (MINUS - UNARY--)
    (NEGATIVEP MINUSP)
    (NEGATIVE-GUTS ABS)
    (NLISTP ATOM)
    (NOT NOT)
    (NUMBERP ACL2-NUMBERP INTEGERP RATIONALP)
    (OR OR)
    (ORDINALP O-P)
    (ORD-LESSP O<)
    (PACK .         "See INTERN and COERCE.")
    (PAIRLIST PAIRLIS$)
    (PLUS + BINARY-+)
    ;;(QUANTIFIER-INITIAL-VALUE)
    ;;(QUANTIFIER-OPERATION)
    (QUOTIENT /)
    (REMAINDER REM MOD)
    (STRIP-CARS STRIP-CARS)
    (SUB1 1-)
    ;;(SUBRP)
    ;;(SUM-CDRS)
    (TIMES * BINARY-*)
    (TRUE . "The symbol T.")
    ;;(TRUEP)
    (UNION UNION-EQUAL UNION-EQ)
    (UNPACK .       "See SYMBOL-NAME and COERCE.")
    (V&C$ .         "See the documentation for DEFEVALUATOR and META.")
    (V&C-APPLY$ .   "See the documentation for DEFEVALUATOR and META.")
    (ZERO .         "The number 0.")
    (ZEROP ZEROP)))

(defconst *nqthm-to-acl2-commands*

; Keep this list in sync with documentation for nqthm-to-acl2.

  '((ACCUMULATED-PERSISTENCE ACCUMULATED-PERSISTENCE)
    (ADD-AXIOM DEFAXIOM)
    (ADD-SHELL .    "There is no shell principle in ACL2.")
    (AXIOM DEFAXIOM)
    (BACKQUOTE-SETTING .
                    "Backquote is supported in ACL2, but not
                     currently documented.")
    (BOOT-STRAP GROUND-ZERO)
    (BREAK-LEMMA MONITOR)
    (BREAK-REWRITE BREAK-REWRITE)
    (CH PBT .       "See also :DOC history.")
    (CHRONOLOGY PBT .
                    "See also :DOC history.")
    (COMMENT DEFLABEL)
    (COMPILE-UNCOMPILED-DEFNS COMP)
    (CONSTRAIN .    "See :DOC encapsulate and :DOC local.")
    (DATA-BASE .    "Perhaps the closest ACL2 analogue of DATA-BASE
                     is PROPS.  But see :DOC history for a collection
                     of commands for querying the ACL2 database
                     (``world'').  Note that the notions of
                     supporters and dependents are not supported in
                     ACL2.")
    (DCL DEFSTUB)
    (DEFN DEFUN DEFMACRO)
    (DEFTHEORY DEFTHEORY)
    (DISABLE DISABLE)
    (DISABLE-THEORY .
                    "See :DOC theories.  The Nqthm command
                     (DISABLE-THEORY FOO) corresponds roughly to the
                     ACL2 command
                     (in-theory (set-difference-theories
                                  (current-theory :here)
                                  (theory 'foo))).")
    (DO-EVENTS LD)
    (DO-FILE LD)
    (ELIM ELIM)
    (ENABLE ENABLE)
    (ENABLE-THEORY .
                    "See :DOC theories.  The Nqthm command
                     (ENABLE-THEORY FOO) corresponds roughly to the
                     ACL2 command
                     (in-theory (union-theories
                                  (theory 'foo)
                                  (current-theory :here))).")
    (EVENTS-SINCE PBT)
    (FUNCTIONALLY-INSTANTIATE .
                    "ACL2 provides a form of the :USE hint that
                     corresponds roughly to the
                     FUNCTIONALLY-INSTANTIATE event of Nqthm. See
                     :DOC lemma-instance.")
    (GENERALIZE GENERALIZE)
    (HINTS HINTS)
    (LEMMA DEFTHM)
    (MAINTAIN-REWRITE-PATH BRR)
    (MAKE-LIB .     "There is no direct analogue of Nqthm's notion of
                     ``library.''  See :DOC books for a description
                     of ACL2's mechanism for creating and saving
                     collections of events.")
    (META META)
    (NAMES NAME)
    (NOTE-LIB INCLUDE-BOOK)
    (PPE PE)
    (PROVE THM)
    (PROVEALL .     "See :DOC ld and :DOC certify-book.  The latter
                     corresponds to Nqthm's PROVE-FILE,which may be
                     what you're interested in, really.")
    (PROVE-FILE CERTIFY-BOOK)
    (PROVE-FILE-OUT CERTIFY-BOOK)
    (PROVE-LEMMA DEFTHM .
                    "See also :DOC hints.")
    (R-LOOP .       "The top-level ACL2 loop is an evaluation loop as
                     well, so no analogue of R-LOOP is necessary.")
    (REWRITE REWRITE)
    (RULE-CLASSES RULE-CLASSES)
    (SET-STATUS IN-THEORY)
    (SKIM-FILE LD-SKIP-PROOFSP)
    (TOGGLE IN-THEORY)
    (TOGGLE-DEFINED-FUNCTIONS EXECUTABLE-COUNTERPART-THEORY)
    (TRANSLATE TRANS TRANS1)
    (UBT UBT U)
    (UNBREAK-LEMMA UNMONITOR)
    (UNDO-BACK-THROUGH UBT)
    (UNDO-NAME .    "See :DOC ubt.  There is no way to undo names in
                     ACL2 without undoing back through such names.
                     However, see :DOC ld-skip-proofsp for
                     information about how to quickly recover the
                     state.")))

(defun nqthm-to-acl2-fn (name state)
  (declare (xargs :guard (symbolp name)))
  (io? temporary nil (mv erp val state)
       (name)
       (let ((prims (cdr (assoc-eq name *nqthm-to-acl2-primitives*)))
             (comms (cdr (assoc-eq name *nqthm-to-acl2-commands*))))
         (pprogn
          (cond
           (prims
            (let ((syms (fix-true-list prims))
                  (info (if (consp prims) (cdr (last prims)) prims)))
              (pprogn
               (if syms
                   (fms "Related ACL2 primitives (use :PE or see documentation ~
                         to learn more):  ~&0.~%"
                        (list (cons #\0 syms))
                        *standard-co*
                        state
                        nil)
                 state)
               (if info
                   (pprogn (fms info
                                (list (cons #\0 syms))
                                *standard-co*
                                state
                                nil)
                           (newline *standard-co* state))
                 state))))
           (t state))
          (cond
           (comms
            (let ((syms (fix-true-list comms))
                  (info (if (consp comms) (cdr (last comms)) comms)))
              (pprogn
               (if syms
                   (fms "Related ACL2 commands (use :PE or see documentation ~
                         to learn more):  ~&0.~%"
                        (list (cons #\0 syms))
                        *standard-co*
                        state
                        nil)
                 state)
               (if info
                   (pprogn (fms info
                                (list (cons #\0 syms))
                                *standard-co*
                                state
                                nil)
                           (newline *standard-co* state))
                 state))))
           (t state))
          (if (or prims comms)
              (value :invisible)
            (pprogn
             (fms "Sorry, but there seems to be no ACL2 notion corresponding ~
                   to the alleged Nqthm notion ~x0.~%"
                  (list (cons #\0 name))
                  *standard-co*
                  state
                  nil)
             (value :invisible)))))))

; Here are functions that can be defined to print out the last part of the
; documentation string for nqthm-to-acl2, using (print-nqthm-to-acl2-doc
; state).

; (defun print-nqthm-to-acl2-doc1 (alist state)
;   (cond
;    ((null alist) state)
;    (t (let* ((x (fix-true-list (cdar alist)))
;              (s (if (atom (cdar alist))
;                     (cdar alist)
;                   (cdr (last (cdar alist))))))
;         (mv-let
;          (col state)
;          (fmt1 "  ~x0~t1--> "
;                (list (cons #\0 (caar alist))
;                      (cons #\1 16))
;                0 *standard-co* state nil)
;          (declare (ignore col))
;          (mv-let
;           (col state)
;           (fmt1 " ~&0"
;                 (list (cons #\0 x))
;                 0 *standard-co* state nil)
;           (declare (ignore col))
;           (pprogn
;            (if (or (null x) (null s))
;                state
;              (fms "~t0" (list (cons #\0 21)) *standard-co* state nil))
;            (if s
;                (mv-let
;                 (col state)
;                 (fmt1 "~@0~%" ; Here % was vertical bar, but emacs 19 has trouble...
;                       (list (cons #\0 s)) 0 *standard-co* state nil)
;                 (declare (ignore col))
;                 state)
;              (newline *standard-co* state))
;            (print-nqthm-to-acl2-doc1 (cdr alist) state))))))))
;
; (defun print-nqthm-to-acl2-doc (state)
;   (pprogn
;    (princ$ "  ~bv[]" *standard-co* state)
;    (fms "  Nqthm functions  -->     ACL2"
;         nil *standard-co* state nil)
;    (fms "  ----------------------------------------~%"
;         nil *standard-co* state nil)
;    (print-nqthm-to-acl2-doc1 *nqthm-to-acl2-primitives* state)
;    (fms "  ========================================~%"
;         nil *standard-co* state nil)
;    (fms "  Nqthm commands   -->     ACL2"
;         nil *standard-co* state nil)
;    (fms "  ----------------------------------------~%"
;         nil *standard-co* state nil)
;    (print-nqthm-to-acl2-doc1 *nqthm-to-acl2-commands* state)
;    (princ$ "  ~ev[]" *standard-co* state)
;    (newline *standard-co* state)
;    (value :invisible)))

(defmacro nqthm-to-acl2 (x)

; Keep documentation for this function in sync with *nqthm-to-acl2-primitives*
; and *nqthm-to-acl2-commands*.  See comment above for how some of this
; documentation was generated.

  (declare (xargs :guard (and (true-listp x)
                              (equal (length x) 2)
                              (eq (car x) 'quote)
                              (symbolp (cadr x)))))
  `(nqthm-to-acl2-fn ,x state))

#+(and gcl (not acl2-loop-only))
(progn
  (defvar *current-allocated-fixnum-lo* 0)
  (defvar *current-allocated-fixnum-hi* 0))

(defun allocate-fixnum-range (fixnum-lo fixnum-hi)
  (declare (xargs :guard (and (integerp fixnum-lo)
                              (integerp fixnum-hi)
                              (>= fixnum-hi fixnum-lo)))
           (type (signed-byte 30) fixnum-lo fixnum-hi))

; This function is simply NIL in the logic but allocates a range of fixnums
; (from fixnum-lo to fixnum-hi) in GCL as a side effect (a side effect which
; should only affect the speed with which ACL2 computes a value, but not the
; value itself up to EQUALity).  In GCL, there is a range of pre-allocated
; fixnums which are fixed to be -1024 to +1023.

  (let ((tmp (- fixnum-hi fixnum-lo)))
    (declare (ignore tmp))
    #+(and gcl (not acl2-loop-only))
    (cond ((or (> fixnum-hi *current-allocated-fixnum-hi*)
               (< fixnum-lo *current-allocated-fixnum-lo*))
           (fms "NOTE:  Allocating bigger fixnum table in GCL.~|"
                nil (standard-co *the-live-state*) *the-live-state*
                nil)
           (system::allocate-bigger-fixnum-range fixnum-lo (1+ fixnum-hi))
           (setq *current-allocated-fixnum-lo* fixnum-lo)
           (setq *current-allocated-fixnum-hi* fixnum-hi))
          (t
           (fms "No further fixnum allocation done:~|  Previous fixnum table ~
                 encompasses desired allocation.~|"
                nil (standard-co *the-live-state*) *the-live-state*
                nil)))
    #+(and (not gcl) (not acl2-loop-only))
    (fms "Fixnum allocation is only performed in GCL.~|"
         nil (standard-co *the-live-state*) *the-live-state*
         nil)
    nil))

; It has been found useful to allocate new space very gradually in Allegro CL
; 6.1 for at least one unusually large job on a version of RedHat Linux (over
; 600MB without this caused GC error; with this call, the corresponding image
; size was cut by very roughly one third and there was no GC error).  However,
; the problem seems to disappear in Allegro CL 6.2.  So we won't advertise
; (document) this utility.

#+allegro
(defmacro allegro-allocate-slowly (&key (free-bytes-new-other '1024)
                                        (free-bytes-new-pages '1024)
                                        (free-percent-new '3)
                                        (expansion-free-percent-old '3)
                                        (expansion-free-percent-new '3))
  `(allegro-allocate-slowly-fn ,free-bytes-new-other ,free-bytes-new-pages
                               ,free-percent-new ,expansion-free-percent-old
                               ,expansion-free-percent-new))

(defun allegro-allocate-slowly-fn (free-bytes-new-other
                                   free-bytes-new-pages
                                   free-percent-new
                                   expansion-free-percent-old
                                   expansion-free-percent-new)

  #-(and allegro (not acl2-loop-only))
  (declare (ignore free-bytes-new-other free-bytes-new-pages free-percent-new
                   expansion-free-percent-old expansion-free-percent-new))
  #+(and allegro (not acl2-loop-only))
  (progn
    (setf (sys:gsgc-parameter :free-bytes-new-other) free-bytes-new-other)
    (setf (sys:gsgc-parameter :free-bytes-new-pages) free-bytes-new-pages)
    (setf (sys:gsgc-parameter :free-percent-new) free-percent-new)
    (setf (sys:gsgc-parameter :expansion-free-percent-old)
          expansion-free-percent-old)
    (setf (sys:gsgc-parameter :expansion-free-percent-new)
          expansion-free-percent-new))
  nil)

; All code for the pstack feature occurs immediately below.  When a form is
; wrapped in (pstk form), form will be pushed onto *pstk-stack* during its
; evaluation.  The stack can be evaluated (during a break or after an
; interrupted proof) by evaluating the form (pstack), and it is
; initialized at the beginning of each new proof attempt (in prove-loop, since
; that is the prover's entry point under both prove and pc-prove).

#-acl2-loop-only
(progn
  (defparameter *pstk-stack* nil)
  (defvar *verbose-pstk* nil)

; The following are only of interest when *verbose-pstk* is true.

  (defparameter *pstk-level* 1)
  (defparameter *pstk-start-time-stack* nil))

(defmacro clear-pstk ()
  #+acl2-loop-only nil
  #-acl2-loop-only
  '(progn (setq *pstk-stack* nil)
          (setq *pstk-level* 1)
          (setq *pstk-start-time-stack* nil)))

(defconst *pstk-vars*
  '(pstk-var-0
    pstk-var-1
    pstk-var-2
    pstk-var-3
    pstk-var-4
    pstk-var-5
    pstk-var-6
    pstk-var-7
    pstk-var-8
    pstk-var-9
    pstk-var-10
    pstk-var-11
    pstk-var-12))

(defun pstk-bindings-and-args (args vars)

; We return (mv bindings new-args fake-args).  Here new-args is a symbol-listp
; and of the same length as args, where each element of args is either a symbol
; or is the value of the corresponding element of new-args in bindings.
; Fake-args is the same as new-args except that state has been replaced by
; <state>.

  (cond
   ((endp args)
    (mv nil nil nil))
   ((endp vars)
    (mv (er hard 'pstk-bindings-and-args
            "The ACL2 sources need *pstk-vars* to be extended.")
        nil nil))
   (t
    (mv-let (bindings rest-args fake-args)
      (pstk-bindings-and-args (cdr args) (cdr vars))
      (cond
       ((eq (car args) 'state)
        (mv bindings
            (cons (car args) rest-args)
            (cons ''<state> rest-args)))
       ((symbolp (car args))
        (mv bindings
            (cons (car args) rest-args)
            (cons (car args) fake-args)))
       (t
        (mv (cons (list (car vars) (car args)) bindings)
            (cons (car vars) rest-args)
            (cons (car vars) fake-args))))))))

(defmacro pstk (form)
  (declare (xargs :guard (consp form)))
  #+acl2-loop-only
  `(check-vars-not-free
    ,*pstk-vars*
    ,form)
  #-acl2-loop-only
  (mv-let (bindings args fake-args)
    (pstk-bindings-and-args (cdr form) *pstk-vars*)
    `(let ,bindings
       (setq *pstk-stack*
             (cons ,(list* 'list (kwote (car form)) fake-args)
                   *pstk-stack*))
       (dmr-flush)
       (when (and *verbose-pstk*
                  (or (eq *verbose-pstk* t)
                      (not (member-eq ',(car form) *verbose-pstk*))))
         (setq *pstk-start-time-stack*
               (cons (get-internal-time) *pstk-start-time-stack*))
         (format t "~V@TCP~D> ~S~%"
                 (* 2 *pstk-level*)
                 *pstk-level*
                 ',(car form))
         (setq *pstk-level* (1+ *pstk-level*)))
       (our-multiple-value-prog1
        ,(cons (car form) args)

; Careful!  We must be careful not to smash any mv-ref value in the forms
; below, in case form returns a multiple value.  So, for example, we use format
; rather than fmt1.

        (when (and *verbose-pstk*
                   (or (eq *verbose-pstk* t)
                       (not (member-eq ',(car form) *verbose-pstk*))))
          (setq *pstk-level* (1- *pstk-level*))
          (format t "~V@TCP~D< ~S [~,2F seconds]~%"
                  (* 2 *pstk-level*)
                  *pstk-level*
                  ',(car form)
                  (/ (- (get-internal-time)
                        (pop *pstk-start-time-stack*))
                     (float internal-time-units-per-second))))
        (setq *pstk-stack* (cdr *pstk-stack*))
        ,@(and (not (eq (car form) 'ev-fncall-meta)) ; overkill in that case
               '((dmr-flush)))
        ,@(and (eq (car form) 'rewrite-atm)
               '((setq *deep-gstack* nil)))))))

(defun pstack-fn (allp state)
  #+acl2-loop-only
  (declare (ignore allp))
  #-acl2-loop-only
  (cond ((and allp (not (eq allp :all)))
         (fmt-abbrev "~%~p0"
                     (list (cons #\0 (if allp
                                         *pstk-stack*
                                       (strip-cars *pstk-stack*))))
                     0 *standard-co* state "~|"))
        (t
         (fms "~p0~|"
              (list (cons #\0 (if allp *pstk-stack* (strip-cars *pstk-stack*))))
              *standard-co*
              state
              (and allp ; (eq allp :all)
                   (cons (world-evisceration-alist state nil)
                         '(nil nil nil))))))
  #-acl2-loop-only
  (if (assoc-eq 'preprocess-clause *pstk-stack*)
      (cw "NOTE:  You may find the hint :DO-NOT '(PREPROCESS) helpful.~|"))
  (value :invisible))

(defmacro pstack (&optional allp)
  `(pstack-fn ,allp state))

(defun verbose-pstack (flg-or-list)
  (declare (xargs :guard (or (eq flg-or-list t)
                             (eq flg-or-list nil)
                             (symbol-listp flg-or-list))))
  #+acl2-loop-only
  flg-or-list
  #-acl2-loop-only
  (setq *verbose-pstk* flg-or-list))

; End of pstack code.

; The following two functions could go in axioms.lisp, but it seems not worth
; putting them in :logic mode so we might as well put them here.

(defun pop-inhibit-output-lst-stack (state)
  (let ((stk (f-get-global 'inhibit-output-lst-stack state)))
    (cond ((null stk) state)
          (t (pprogn (f-put-global 'inhibit-output-lst
                                   (car stk)
                                   state)
                     (f-put-global 'inhibit-output-lst-stack
                                   (cdr stk)
                                   state))))))

(defun push-inhibit-output-lst-stack (state)
  (f-put-global 'inhibit-output-lst-stack
                (cons (f-get-global 'inhibit-output-lst state)
                      (f-get-global 'inhibit-output-lst-stack state))
                state))

(defun set-gc-threshold$-fn (new-threshold verbose-p)

; This function is used to manage garbage collection in a way that is friendly
; to ACL2(p).  As suggested by its name, it sets (in supported Lisps), to
; new-threshold, the number of bytes to be allocated before the next garbage
; collection.  It may set other gc-related behavior as well.

  (declare (ignorable verbose-p))
  (let ((ctx 'set-gc-threshold$))
    (cond
     ((not (posp new-threshold))
      (er hard ctx
          "The argument to set-gc-threshold$ must be a positive integer, so ~
           the value ~x0 is illegal."
          new-threshold))
     (t
      #-acl2-loop-only
      (progn
        #+ccl
        (ccl:set-lisp-heap-gc-threshold new-threshold)
        #+(and ccl acl2-par)
        (progn (cw "Disabling the CCL Ephemeral GC for ACL2(p)~%")
               (ccl:egc nil))
        #+sbcl
        (setf (sb-ext:bytes-consed-between-gcs) (1- new-threshold))
        #+(and lispworks lispworks-64bit)
        (progn
          (when (< new-threshold (expt 2 20))
            (let ((state *the-live-state*))

; Avoid warning$-cw, since this function is called by LP outside the loop.

              (warning$ 'set-gc-threshold$ nil
                        "Ignoring argument to set-gc-threshold$, ~x0, because ~
                         it specifies a threshold of less than one megabyte.  ~
                         Using default threshold of one megabyte.")))

; Calling set-gen-num-gc-threshold sets the GC threshold for the given
; generation of garbage.

          (system:set-gen-num-gc-threshold 0
                                           (max (expt 2 10)
                                                (/ new-threshold (expt 2 10))))
          (system:set-gen-num-gc-threshold 1
                                           (max (expt 2 17)
                                                (/ new-threshold (expt 2 3))))
          (system:set-gen-num-gc-threshold 2
                                           (max (expt 2 18)
                                                (/ new-threshold (expt 2 2))))

; This call to set-blocking-gen-num accomplishes two things: (1) It sets the
; third generation as the "final" generation -- nothing can be promoted to
; generation four or higher.  (2) It sets the GC threshold for generation 3.

          (system:set-blocking-gen-num 3 :gc-threshold (max (expt 2 20)
                                                            new-threshold)))
        #-(or ccl sbcl (and lispworks lispworks-64bit))
        (when verbose-p
          (let ((state *the-live-state*))

; Avoid warning$-cw, since this function is called by LP outside the loop.

            (warning$ 'set-gc-threshold$ nil
                      "We have not yet implemented setting the garbage ~
                       collection threshold for this Lisp.  Contact the ACL2 ~
                       implementors to request such an implementation."))))
      t))))

(defmacro set-gc-threshold$ (new-threshold &optional (verbose-p 't))

; See comments in set-gc-threshold$-fn.

  `(set-gc-threshold$-fn ,new-threshold ,verbose-p))
