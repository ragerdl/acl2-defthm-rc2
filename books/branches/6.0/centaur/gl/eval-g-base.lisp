

(in-package "GL")

(include-book "defapply")
(include-book "generic-geval")


(defapply apply-base
  (BINARY-*
   BINARY-+
   PKG-WITNESS
;   UNARY-/
   UNARY--
   COMPLEX-RATIONALP
;   BAD-ATOM<=
   ACL2-NUMBERP
   SYMBOL-PACKAGE-NAME
   INTERN-IN-PACKAGE-OF-SYMBOL
   CODE-CHAR
;   DENOMINATOR
   CDR
;   COMPLEX
   CAR
   CONSP
   SYMBOL-NAME
   CHAR-CODE
   IMAGPART
   SYMBOLP
   REALPART
;   NUMERATOR
   EQUAL
   STRINGP
   RATIONALP
   CONS
   INTEGERP
   CHARACTERP
   <
   COERCE
   booleanp
   logbitp
   binary-logand
   binary-logior
   lognot
   ash
   integer-length
   floor
   mod
   truncate
   rem
   acl2::boolfix

   ;; these are from the constant *expandable-boot-strap-non-rec-fns*.
   NOT IMPLIES
   EQ ATOM EQL = /= NULL ENDP ZEROP ;; SYNP
   PLUSP MINUSP LISTP ;; RETURN-LAST causes guard violation
   ;; FORCE CASE-SPLIT
   ;; DOUBLE-REWRITE
   ))






(def-eval-g eval-g-base apply-base)

(in-theory (disable eval-g-base))
