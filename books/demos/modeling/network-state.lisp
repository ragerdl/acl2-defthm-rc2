; This books demonstrates how we could model network state and an attacker that
; would be a "Man in the middle" between a client and a server.  This file is
; the second of two that perform this modeling.  This second file,
; network-state.lisp, is similar to the first file, but it uses more advanced
; features of ACL2 (like defn, defaggregate, b*, guards, defun+ and its output
; signatures, etc.).

; The concepts in this book are based off Rager's JFKr model, which can be
; found in books/security/jfkr.lisp and is explained in "An Executable Model
; for JFKr", by David Rager, which was included in the 2009 ACL2 Workshop.

; Copyright David Rager 2012.


; Suppose we have the following english description of a protocol.

; There are two actors, a client/initiator and a server/responder.  In this
; case, the server is providing a simple service -- it looks for a request on
; the network (presumably sent to the responder), squares the number included
; within the request, and sends the result back on the network.

; The server will keep track of the number of requests that it has served.

(in-package "ACL2")

(include-book "make-event/eval" :dir :system)
(include-book "cutil/defaggregate" :dir :system)
(include-book "cutil/deflist" :dir :system)
(include-book "misc/defun-plus" :dir :system)
(include-book "tools/bstar" :dir :system)

;;;;;;;;;;;;;;;;;;;;;;;
; Setup client state
;;;;;;;;;;;;;;;;;;;;;;;

(defn unknown-or-integerp (x)
  (or (equal x :unknown)
      (integerp x)))

(cutil::defaggregate client-state
  (number-to-square answer)
  :require ((integer-p-of-client-state->number-to-square
             (integerp number-to-square))
            (unknown-or-integerp-of-client-state->answer
             (unknown-or-integerp answer)))
  :tag :client-state)

(defconst *initial-number-to-square* 8)
(defconst *initial-result* :unknown)
(defconst *initial-client*
  (make-client-state
   :number-to-square *initial-number-to-square*
   :answer *initial-result*))

;;;;;;;;;;;;;;;;;;;;;;;
; Setup server state
;;;;;;;;;;;;;;;;;;;;;;;

(cutil::defaggregate server-state
 (requests-served)
 :require ((integerp-of-server-state->requests-served
            (integerp requests-served)
            :rule-classes ((:type-prescription))))
 :tag :server-state)

(defconst *intial-number-of-requests-served* 0)
(defconst *initial-server*
  (make-server-state
   :requests-served *intial-number-of-requests-served*))

;;;;;;;;;;;;;;;;;;;;;;
; Setup network state
;;;;;;;;;;;;;;;;;;;;;;

(cutil::defaggregate message
  (tag payload)
  :require ((keywordp-of-message->tag
             (keywordp tag))
            (integerp-of-message->payload
             (integerp payload)
             :rule-classes ((:type-prescription))))
  :tag :message)

(defn id-p (x)

; Would rather make this a macro, but since we can't do that and use deflist,
; we later create a forward chaining rule.

  (keywordp x))

(defthm id-p-implies-keywordp
  (implies (id-p x)
           (keywordp x))
  :rule-classes :forward-chaining)

(cutil::defaggregate network-packet
  (sender dest message)
  :require ((id-p-of-network-packet->sender
             (id-p sender))
            (id-p-of-network-packet->dest
             (id-p dest))
            (message-p-of-network-packet->message
             (message-p message)))
  :tag :network-packet)

(in-theory (disable id-p)) ; we want to reason about id-p, not keywordp

(defconst *initial-network*
  nil)

(cutil::deflist network-state-p (x)
  (network-packet-p x)
  :elementp-of-nil nil
  :true-listp t)

(encapsulate ()

 (local (include-book "arithmetic/top" :dir :system))

 (defun+ square (x)
   (declare (xargs :guard t ; (integerp x)
                   :output (integerp (square x))))
   (cond ((integerp x)
          (expt x 2))
         (t 0))))
 
(defconst *client-id* :client)
(defconst *server-id* :server)

(defun retrieve-network-message (dest network-st)
; Returns the message and a new network state, which does not include the new
; message
  (declare (xargs :guard (and (id-p dest)
                              (network-state-p network-st))))
  (cond ((atom network-st)
         (mv nil nil))
        (t 
         (let ((packet (car network-st)))
           (cond ((equal (network-packet->dest packet) dest)
                  (mv packet (cdr network-st)))
                 (t (mv-let (msg network-st-recursive)
                            (retrieve-network-message dest 
                                                      (cdr network-st))
                            (mv msg 
                                (cons (car network-st)
                                      network-st-recursive)))))))))
(defthm retrieve-network-message-output-lemma
  (implies (and (id-p dest)
                (network-state-p network-st))
           (implies (car (retrieve-network-message dest network-st))
                    (network-packet-p (car (retrieve-network-message dest
                                                                     network-st))))))
(defthm retrieve-network-message-returns-network-state-p
  (implies (network-state-p network-st)
           (network-state-p (mv-nth 1 (retrieve-network-message x network-st)))))


(defun+ make-square-request (value-to-square)
  (declare (xargs :guard (integerp value-to-square)
                  :output (network-packet-p (make-square-request value-to-square))))
  (make-network-packet
   :sender *client-id*
   :dest *server-id* 
   :message (make-message :tag :request
                          :payload value-to-square)))

(defun+ client-step1 (client-st network-st)
  (declare (xargs :guard (and (client-state-p client-st)
                              (network-state-p network-st))
                  :output (and (client-state-p (car (client-step1 client-st network-st)))
                               (network-state-p (cadr (client-step1 client-st network-st))))))
  (mv client-st
      (cons
       (make-square-request
        (client-state->number-to-square client-st))
       network-st)))

(defn print-states (client-st server-st network-st)
  (prog2$ 
   (cw "~%Client state is: ~x0~%" client-st)
   (prog2$
    (cw "Server state is: ~x0~%" server-st)
    (cw "Network state is: ~x0~%" network-st))))

#+demo-only ; skipped during book certification
(let ((client-st *initial-client*)
      (server-st *initial-server*)
      (network-st *initial-network*))
  (b* (((mv client-st network-st)
        (client-step1 client-st network-st)))
    (print-states client-st server-st network-st)))

(defun+ make-square-response (dest result)
  (declare (xargs :guard (and (id-p dest)
                              (integerp result))
                  :output (network-packet-p (make-square-response dest result))))
  (make-network-packet :sender *server-id*
                       :dest dest 
                       :message (make-message :tag :answer
                                              :payload result)))

(defun+ server-step1 (server-st network-st)
  (declare (xargs :guard (and (server-state-p server-st)
                              (network-state-p network-st))
                  :output (and (server-state-p (car (server-step1 server-st
                                                                  network-st)))
                               (network-state-p (cadr (server-step1 server-st network-st))))))
  (b* (((mv packet network-st)
        (retrieve-network-message *server-id* network-st))
       ((when (null packet))
        (prog2$ (cw "Missing packet~%")
                (mv server-st network-st))))
    (mv (change-server-state server-st
                             :requests-served 
                             (+ 1 (server-state->requests-served server-st)))
        (cons 
         (make-square-response
          (network-packet->sender packet)
          (square (message->payload (network-packet->message packet))))
         network-st))))

#+demo-only
(let ((client-st *initial-client*)
      (server-st *initial-server*)
      (network-st *initial-network*))
  (mv-let (client-st network-st)
          (client-step1 client-st network-st)
          (mv-let (server-st network-st)
                  (server-step1 server-st network-st)
                  (print-states client-st server-st
                                network-st))))



(defun+ client-step2 (client-st network-st)
  (declare (xargs :guard (and (client-state-p client-st)
                              (network-state-p network-st))
                  :output (and (client-state-p (car (client-step2 client-st
                                                                  network-st)))
                               (network-state-p (cadr (client-step2 client-st network-st))))))
  (b* (((mv packet network-st)
        (retrieve-network-message *client-id* network-st))
       ((when (null packet))
        (prog2$ (cw "Missing packet~%")
                (mv client-st network-st))))
    (mv (change-client-state 
         client-st
         :answer (message->payload (network-packet->message packet)))
        network-st)))

#+demo-only
(b* ((client-st *initial-client*) ; not symbolic, because it has concrete initialization
     (server-st *initial-server*)
     (network-st *initial-network*)
     ((mv client-st network-st)
      (client-step1 client-st network-st))
     (- (print-states client-st server-st network-st))
     ((mv server-st network-st)
      (server-step1 server-st network-st))
     (- (print-states client-st server-st network-st))
     ((mv client-st network-st)
      (client-step2 client-st network-st)))
  (print-states client-st server-st network-st))

(defthm honest-square-is-good-concrete
  (b* ((client-st *initial-client*) ; not symbolic, because it has concrete initialization
       (server-st *initial-server*)
       (network-st *initial-network*)
       ((mv client-st network-st)
        (client-step1 client-st network-st))
       ((mv ?server-st network-st)
        (server-step1 server-st network-st))
       ((mv client-st ?network-st)
        (client-step2 client-st network-st)))
    (equal (expt (client-state->number-to-square client-st) 2)
           (client-state->answer client-st))))

(defthm honest-square-is-good-symbolic-simulation
  (implies (and (client-state-p client-st) ; is symbolic
                (server-state-p server-st)
                (network-state-p network-st))
           (b* (((mv client-st network-st)
                 (client-step1 client-st network-st))
                ((mv ?server-st network-st)
                 (server-step1 server-st network-st))
                ((mv client-st ?network-st)
                 (client-step2 client-st network-st)))
             (equal (expt (client-state->number-to-square client-st) 2)
                    (client-state->answer client-st)))))
           
(defun+ man-in-the-middle-specific-attack (network-st)
  (declare (xargs :guard (network-state-p network-st)
                  :output (network-state-p (man-in-the-middle-specific-attack
                                            network-st))))

; Changes the number that the client requested

  (b* (((mv original-packet network-st)
        (retrieve-network-message *server-id* network-st))
       ((when (null original-packet))
        (prog2$ (cw "Missing packet~%")
                network-st)))
    (cons (make-square-request 
           (+ 20 (message->payload (network-packet->message
                                    original-packet))))
          network-st)))

#+demo-only
(b* ((client-st *initial-client*) ; not symbolic, because it has concrete initialization
     (server-st *initial-server*)
     (network-st *initial-network*)
     ((mv client-st network-st)
      (client-step1 client-st network-st))
     (- (print-states client-st server-st network-st))
     (- (cw "~%Attack!!!~%~%"))
     (network-st (man-in-the-middle-specific-attack network-st))
     (- (print-states client-st server-st network-st))
     (- (cw "~%Done attacking~%~%"))
     ((mv server-st network-st)
      (server-step1 server-st network-st))
     (- (print-states client-st server-st network-st))
     ((mv client-st network-st)
      (client-step2 client-st network-st)))
  (print-states client-st server-st network-st))


; We could leave attack1 and attack2 completely unconstrained.  We could be a
; little more realistic and at least define versions that return a
; network-state-p.  However, this difference will not affect our ability to not
; prove the theorem below (it will still be false).  Thus, we opt for the
; simple call to defstub, so that the reader can more clearly see that we allow
; the attacker to anything their heart desires to the network state.

(defstub attack1 (*) => *) 
(defstub attack2 (*) => *)

(must-fail

; Technically being unable to prove this theorem in ACL2 doesn't mean that the
; theorem isn't valid.  However, if we believed the theorem to be valid, we
; would relentlessly examine the feedback from ACL2 until we figured out how to
; make ACL2 agree with our belief.  But, we happen to know that the theorem
; isn't true, so we leave it as is.
 
 (defthm |bad-square-is-good?-with-double-attack|
   (implies (and (client-state-p client-st) ; is symbolic
                 (server-state-p server-st)
                 (network-state-p network-st))
            (b* (((mv client-st network-st)
                  (client-step1 client-st network-st))
                 (network-st (attack1 network-st)) ; ATTACK!!!
                 ((mv ?server-st network-st)
                  (server-step1 server-st network-st))
                 (network-st (attack2 network-st)) ; ATTACK!!!
                 ((mv client-st ?network-st)
                  (client-step2 client-st network-st)))
              (equal (expt (client-state->number-to-square client-st) 2)
                     (client-state->answer client-st))))))