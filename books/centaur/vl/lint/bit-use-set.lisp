; VL Verilog Toolkit
; Copyright (C) 2008-2014 Centaur Technology
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

(in-package "VL")
(include-book "../toe/toe-preliminary")
;; (include-book "../wf-reasonable-p")
(include-book "disconnected")
(include-book "../mlib/hierarchy")
(include-book "../mlib/allexprs")
(include-book "../mlib/lvalues")
(include-book "../mlib/reportcard")
(include-book "../util/cwtime")
(include-book "use-set-ignore")
(include-book "std/bitsets/bitsets" :dir :system)
(local (include-book "../util/arithmetic"))
(local (include-book "../util/osets"))

(defsection bit-level-use-set
  :parents (lint)
  :short "A bit-level tool that analyzes a module to find bits of wires that
are either unused (i.e., they never drive any other wire or affect any control
decision), or unset (i.e., they are never driven by anything.)"

  :long "<p>Our analysis proceeds in two passes.  Our first pass processes the
innermost submodules first and moves upward toward the top-level modules.  In
this pass we compute the \"local\" use/set information for each module, and
propagate the information from lower-level modules upward to the superior
modules.  Our second pass goes the opposite way, working from high-level
modules down to low-level modules, to propagate \"used/set from above\"
information down to the leaves.</p>

<p>Leaf modules (those with no submodules) are easy to analyze.  For instance:</p>

<ul>
<li>Given @('assign foo = b + c'), we say all the wires for b and c are used and
    that all of the wires for a are set.</li>

<li>Given @('and (o, a, b)'), we say the wire for o is set and the wires for a
     and b are used.</li>

<li>Given a procedural statement like @('if (foo) bar = baz'), we say (1) the
     wires for foo are used since they affect the control flow, (2) the wires
     for bar are set since they are being assigned to, and (3) the wires for
     baz are used since they are driving bar.</li>
</ul>

<p>We take a straightforward approach to this, so it is relatively easy to fool
the tool.  For instance, an assignment like @('assign foo = foo') will trick
our tool into thinking that foo is both unused and unset.  Similarly, if we
just write @('assign foo = bar & 0'), then we'll still think bar is used even
though it's really not relevant.</p>

<p>(Perhaps we should eventually write an E-level analysis that, say, does a
symbolic simulation, uses basic constant folding and rewriting, then finally
looks at the @(see acl2::aig-vars) or something similar to try to identify
wires that aren't used.  But this would be quite a bit of computation, so we
haven't really considered it.)</p>

<p>Handling submodule instances is trickier.  To make this concrete, imagine
that we are trying to determine the used/set wires in module @('super'), where
we have the following scenario:</p>

@({
      Picture form:                      Verilog form:

        +----------------------+           module super (...) ;
        |      A               |             ...
        |   +--|----------+    |             sub mysub (.B(A), ...);
        |   |  B          |    |             ...
        |   |         sub |    |           endmodule
        |   +-------------+    |
        |               super  |
        +----------------------+
})

<p>The tricky part is: are A's wires used/set?</p>

<p><b>Old Approach</b>.  In the original, non bit-level use-set tool, I
approximated the answer by just looking at the declaration for port B:</p>

@({
   Type of B  | Conclusion for Super      |  Conclusion for Sub
   -----------+---------------------------+-----------------------------
   input      |  A is used (by sub)       |  B is set      (by super)
   output     |  A is set (by sub)        |  B is used     (by super)
   inout      |  A is used/set (by sub)   |  B is used/set (by super)
   -----------+---------------------------+-----------------------------
})

<p>But this approach has some serious problems.  First, the input/output labels
on ports are really pretty meaningless in Verilog, e.g., you can assign to an
input or read from an output.  I call this <b>backflow</b>.  Because of
backflow, we might sometimes draw the wrong conclusions about whether A is used
or set.</p>

<p>Worse, imagine that B is an input port and is not used in sub; A is not set
in super.  (This sort of thing is common: the designers might deprecate a port,
but keep it in the module even though it is not actually used.)  When we draw
the above conclusions, we will think that A is \"used but not set\" in super
and thus we will flag A as being a serious concern!  We will similarly think
that B is \"set but not used,\" which is a lesser concern but still noisy.  The
inverse problem happens with a deprecated output port that isn't actually
driven by the submodule or used by the supermodule.  Taken over the whole
design, these problems cause a lot of noise in the analysis that distracts us
from the warnings that really are serious.</p>

<p><b>New Approach</b>.  In our new tool, we no longer automatically assume
that the ports of a module are used or set.  In other words, after we process
sub, B will only be marked as used/set if something within sub actually
uses/sets it.  (BOZO: we may need to make an exception for top-level modules).
Also, since we now carry out our analysis in dependency order, by the time we
are analyzing super, we have already analyzed sub; when we get to A, we can
tell whether B was used/set within sub.</p>

<p>With these changes, there are now a couple of easy cases:</p>

<ul>

<li>If B is set by something in sub, then we think A should be regarded as set
in super.</li>

<li>If B is used by something in sub, then we think A should be regarded as
used in super.</li>

</ul>

<p>These inferences can be made separately -- that is, if B is both used and
set, then we want to mark A as both used and set.  Also, note that these
inferences pay no attention to whether B is marked as an input, output, or
inout, so we will not be fooled by backflow through incorrectly labeled
ports.</p>

<p>What should we do if B is unused and/or unset?  It seems most sensible to
just not infer anything about A.  If we took this approach, we would just think
that A was a \"spurious\" wire (neither used nor set).  This is a little
strange, because usually we would think that a spurious wire doesn't appear
anywhere in the module except for its declaration.  The logic designer who goes
to remove the spurious wire could be surprised that it actually occurs
somewhere in the module, and might not understand why the tool isn't regarding
it as being used.</p>

<p>So, we try to address this by tracking some new information.  The
input/output/inout label for port B sort of tells us how B is supposed to be
used.  We say:</p>

<ul>
<li>B is \"falsely used\" whenever it is an input/inout that is unused, and</li>
<li>B is \"falsely set\" whenever it is an output/inout that is unset.</li>
</ul>

<p>We allow falsely used/set to propagate through module instances.  That is,
whenever B is falsely used/set, we say A is also falsely used/set.  This allows
us to distinguish between wires that are only used to drive deprecated ports
from truly spurious wires.</p>

<h3>IMPORTANT WHITEBOARD NOTES FROM JARED</h3>

@({
    PORTS.

    Locally Truly     | Somewhere above   | CLASS                      NOTES                               MAYBE NOTES
                      |                   |                            (to tell the user)
     USED   SET       |   USED   SET      |
    ------------------+-------------------+-------------------------------------------------------------------------------------------------------
      0      0        |     0     0       | spurious port              never used/set above                {{ same 'looks set/used' messages   }}
      0      0        |     0     1       | spurious port              sometimes set, never used above     {{ as for regular wires for submods }}
      0      0        |     1     0       | spurious port              sometimes used, never set above     {{                                  }}
      0      0        |     1     1       | spurious port              never used above                    {{                                  }}
                      |                   |
    'output':         |                   |
      0      1        |     0     0       | unnecessary output *       never used/set above
      0      1        |     0     1       | possible trainwreck **     none
      0      1        |     1     0       | fine                       none
      0      1        |     1     1       | possible trainwreck **     none
                      |                   |
    'input':          |                   |
      1      0        |     0     0       | unset port (yikes!) **     never used/set above
      1      0        |     0     1       | fine                       none
      1      0        |     1     0       | unset port (yikes!) **     sometimes used, never set above
      1      0        |     1     1       | fine                       none
                      |                   |
    'inout':          |                   |
      1      1        |     0     0       | unnecessary port           never used/set above
      1      1        |     0     1       | horrible trainwreck **     none
      1      1        |     1     0       | fine                       none
      1      1        |     1     1       | horrible trainwreck **     none
    ------------------+-------------------+-------------------------------------------------------------------------------------------------------


    NON-PORT WIRES.

    Locally Truly     | Somewhere above   | CLASS          NOTES
                      |                   |                (to tell the user)
     USED   SET       |   USED   SET      |
    ------------------+-------------------+------------------------------------------------
      0      0        |     0     0       | spurious       none
      0      0        |     0     1       | spurious       looks set, but isn't
      0      0        |     1     0       | spurious       looks used, but isn't
      0      0        |     1     1       | spurious       looks used and set, but isn't
                      |                   |
      0      1        |     0     0       | unused         none
      0      1        |     0     1       | unused         none
      0      1        |     1     0       | unused         looks used, but isn't
      0      1        |     1     1       | unused         looks used, but isn't
                      |                   |
      1      0        |     0     0       | unset          none
      1      0        |     0     1       | unset          looks set, but isn't
      1      0        |     1     0       | unset          none
      1      0        |     1     1       | unset          looks set, but isn't
                                          |
      1      1        |     0     0       | fine           none
      1      1        |     0     1       | fine           none
      1      1        |     1     0       | fine           none
      1      1        |     1     1       | fine           none
    ------------------+-------------------+------------------------------------------------
})")

(local (xdoc::set-default-parents bit-level-use-set))

;; BOZO axe all-wirealists, memoizing vl-module-wirealist seems better...

(define vl-modulelist-all-wirealists
  :parents (vl-wirealist-p)
  :short "Safely generate the (fast) wirealists for a list of modules."
  ((x vl-modulelist-p))
  :returns
  (mv (reportcard vl-reportcard-p :hyp :fguard)
      (all-wirealists
       "Fast alist binding every module name to its wirealist."
       (equal (hons-assoc-equal name all-wirealists)
              (let ((mod (vl-find-module name x)))
                (and mod
                     (cons name (mv-nth 2 (vl-module-wirealist mod nil))))))
       :hyp :fguard))

  (b* (((when (atom x))
        (mv nil nil))

       (car-name (vl-module->name (car x)))

       ((mv reportcard cdr-wire-alists)
        (vl-modulelist-all-wirealists (cdr x)))

       ((mv ?successp car-warnings car-wire-alist)
        (vl-module-wirealist (car x) nil))

       (reportcard
        (if (consp car-warnings)
            (vl-extend-reportcard-list car-name car-warnings reportcard)
          reportcard))

       (wire-alists
        (hons-acons car-name car-wire-alist cdr-wire-alists)))

    (mv reportcard wire-alists)))

  #||

; Some performance work.

 (progn
  (include-book
    "serialize/serialize" :dir :system)
  (include-book
    "serialize/unsound-read" :dir :system)
  (include-book
    "centaur/misc/memory-mgmt-raw" :dir :system)
  (value-triple (acl2::set-max-mem ;; newline to fool limits scanner
    (* 30 (expt 2 30))))
  (value-triple (acl2::hons-resize :addr-ht 10000000))
  (defconst *mods*
    (cdr (assoc :mods
                (serialize::unsound-read "/n/fv2/translations/stable/cnq-speedsim/xdat.sao"
                                         :verbosep t
                                         :honsp t)))))

  (defun test (x)
    (declare (xargs :mode :program)
             (ignorable x))
    (b* (((mv ?warnings ?walists)
          (vl-modulelist-all-wirealists x)))
     (fast-alist-free warnings)
     (fast-alist-free walists)
     nil))

  (prog2$ (gc$)
          (time$ (test *mods*)))

; OLD NOTES.  (These results are all bogus because they are from before
; fast-cat.)  Initial versions were around 27.5 seconds.  New fancy
; no-duplicates check with hons-acons and hons-get symbols already interned:
; 36.7 seconds, 518 MB allocated, 129k faults.  Very sucky.  With no duplicate
; checking at all (just to see how much this matters) 25.26 seconds, 457 mb
; allocated, 112k faults So this is already pretty fast, the duplicate check is
; costing us about 6% of the runtime.  END OLD NOTES.

; NEW NOTES.  Fast-cat.  Optimized vl-emodwires-from-high-to-low.
;
; BASELINE RUNS: 21.51 sec avg

 (/ (+
    22.081 ;sec, 740,903,936 MB, 182K minor faults
    21.222 ;sec, 741,059,824 MB, 181K minor faults
;;    26.579 ;sec, ..., but might have had interference
    21.876 ;sec, ...
    21.619 ;sec, ...
    21.084 ;sec, ...
    21.185 ;sec
   ) 6.0) = 21.51 sec


; Runs with duplicate checking disabled (unsound): 19.74 sec avg
; This just lets us see how expensive the duplicate checks are.

 (/ (+
     20.475 ;sec, 456 MB allocated, no faults <-- interesting
     19.267 ;sec, 455 MB allocated
     19.407
     19.840)
    4) = 19.74 sec

; So duplicate-checking is costing us 1.77 seconds (8.2% of the runtime)

 (prog2$ (gc$)
         (time$ (test *mods*)))

 ; Duplicate-checking re-enabled.
 ; Disable T/F/NIL checking in plain-wire generation.

  #||
  (/ (+
     20.768 ; sec, 740 MB allocated
     20.910
     21.225
     22.820) 4.0) = 21.430
  ||#

  ; So the T/F/NIL check is totally inconsequential, less than 1%.

 ||#


(define vl-nowarn-all-wirealists
  :parents (vl-wirealist-p)
  :short "Wrapper for @(see vl-modulelist-all-wirealists) that ignores any
warnings."
  ((x vl-modulelist-p))
  :returns all-walists
  :enabled t
  :long "<p>We leave this enabled.  It's mostly useful for guards.</p>"

  (b* (((mv reportcard all-walists)
        (vl-modulelist-all-wirealists x)))
    (fast-alist-free reportcard)
    all-walists))


;; (defthm vl-portdecl->dir-default
;;   (implies (and (not (equal (vl-portdecl->dir x) :vl-input))
;;                 (not (equal (vl-portdecl->dir x) :vl-output))
;;                 (force (vl-portdecl-p x)))
;;            (equal (vl-portdecl->dir x)
;;                   :vl-inout)))

;; (defthm vl-compounstmt->ctrl-when-timingstmt
;;   ;; BOZO move to stmt tools
;;   (implies (and (equal (vl-compoundstmt->type x) :vl-timingstmt)
;;                 (force (vl-compoundstmt-p x)))
;;            (vl-compoundstmt->ctrl x))
;;   :hints(("Goal"
;;           :use ((:instance VL-COMPOUNDSTMT-BASIC-CHECKSP-OF-VL-COMPOUNDSTMT))
;;           :in-theory (enable vl-compoundstmt-basic-checksp))))



(define us-portdecllist-bits
  :short "Generate all the bits for the port declarations."
  ((x      vl-portdecllist-p)
   (walist vl-wirealist-p))
  :returns (mv (successp booleanp :rule-classes :type-prescription)
               (warnings vl-warninglist-p)
               (bits     true-listp :rule-classes :type-prescription))
  :long "<p>This seems pretty reasonable, since we've already checked in
  vl-modulelist-check-namespace that the ports overlap with the net
  declarations.</p>"

  (b* (((when (atom x))
        (mv t nil nil))
       (lookup (hons-get (vl-portdecl->name (car x)) walist))
       ((unless lookup)
        (b* ((w (make-vl-warning :type :vl-bad-portdecl
                                 :msg "~a0: no corresponding wires."
                                 :args (list (car x))
                                 :fatalp t
                                 :fn __function__)))
          (mv nil (list w) nil)))
       ((mv successp warnings bits)
        (us-portdecllist-bits (cdr x) walist))
       ((unless successp)
        (mv nil warnings bits)))
    (mv t warnings (append (cdr lookup) bits)))
  ///
  (defthm vl-emodwirelist-p-of-us-portdecllist-bits
    (implies (and (force (vl-portdecllist-p x))
                  (force (vl-wirealist-p walist)))
             (vl-emodwirelist-p (mv-nth 2 (us-portdecllist-bits x walist))))))


(define us-check-port-bits
  :short "Possibly extends the reportcard."
; This is almost the same as vl-check-port-bits.  The idea is to make sure that
; each module's ports and port declarations agree with one another.  I wanted to
; use vl-check-port-bits directly, but it complains about inouts and just isn't
; quite what we need.

  ((x vl-module-p)
   (walist vl-wirealist-p)
   (reportcard vl-reportcard-p))

  :returns (new-reportcard vl-reportcard-p
                        :hyp (and (force (vl-module-p x))
                                  (force (vl-reportcard-p reportcard))))

  (b* (((vl-module x) x)

       ((mv successp warnings port-bits) (vl-portlist-msb-bit-pattern x.ports walist))
       ((unless successp)
        (vl-extend-reportcard-list x.name warnings reportcard))

       ((mv successp warnings decl-bits) (us-portdecllist-bits x.portdecls walist))
       ((unless successp)
        (vl-extend-reportcard-list x.name warnings reportcard))

       ;; Now some extra sanity checks.
       (flat-ports   (flatten port-bits))
       (flat-ports-s (mergesort flat-ports))
       (decl-bits-s  (mergesort decl-bits))

       ;; Check: unique bits for all port declarations.
       (reportcard
        (if (mbe :logic (uniquep decl-bits)
                 :exec (same-lengthp decl-bits decl-bits-s))
            reportcard
          (b* ((dupe-names (duplicated-members (vl-portdecllist->names x.portdecls)))
               (dupe-bits  (duplicated-members decl-bits))
               (w (if dupe-names
                      (make-vl-warning
                       :type :vl-bad-portdecls
                       :msg "The following ports are illegally declared ~
                               more than once: ~&0."
                       :args (list dupe-names)
                       :fatalp t
                       :fn 'us-check-port-bits)
                    (make-vl-warning
                     :type :vl-programming-error
                     :msg "Failed to generate unique portdecl bit names ~
                             even though the portdecls have unique names.  ~
                             Jared thinks this should be impossible unless ~
                             the wire alist is invalid. Duplicate bits: ~&0."
                     :args (list (vl-verilogify-emodwirelist dupe-bits))
                     :fatalp t
                     :fn 'us-check-port-bits))))
            (vl-extend-reportcard x.name w reportcard))))

       ;; Check: unique bits for all ports.
       (reportcard
        (if (mbe :logic (uniquep flat-ports)
                 :exec (same-lengthp flat-ports-s flat-ports))
            reportcard
          (b* ((dupe-bits (duplicated-members flat-ports))
               (w (make-vl-warning
                   :type :vl-bad-ports
                   :msg "The following wires are directly connected to ~
                           multiple ports: ~&0."
                   :args (list (vl-verilogify-emodwirelist dupe-bits))
                   :fatalp t
                   :fn 'us-check-port-bits)))
            (vl-extend-reportcard x.name w reportcard))))

       ;; Check: every declared bit is in a port, and vice versa.
       (reportcard
        (if (equal decl-bits-s flat-ports-s)
            reportcard
          (b* ((extra-port-bits (difference flat-ports-s decl-bits-s))
               (extra-decl-bits (difference decl-bits-s flat-ports-s))
               (w1 (and extra-port-bits
                        (make-vl-warning
                         :type :vl-bad-ports
                         :msg "The following wires are used in ports, but ~
                                 have no corresponding port declarations: ~&0."
                         :args (list (vl-verilogify-emodwirelist extra-port-bits))
                         :fatalp t
                         :fn 'us-check-port-bits)))
               (w2 (and extra-decl-bits
                        (make-vl-warning
                         :type :vl-bad-ports
                         :msg "The following wires have port declarations, ~
                                 but are not used in any ports: ~&0."
                         :args (list (vl-verilogify-emodwirelist extra-decl-bits))
                         :fatalp t
                         :fn 'us-check-port-bits))))
            (cond ((and w1 w2)
                   (vl-extend-reportcard-list x.name (list w1 w2) reportcard))
                  (w1
                   (vl-extend-reportcard x.name w1 reportcard))
                  (w2
                   (vl-extend-reportcard x.name w2 reportcard))
                  (t
                   reportcard))))))
    reportcard))

(define us-modulelist-check-port-bits
  ((x           vl-modulelist-p)
   (mods        vl-modulelist-p)
   (all-walists (equal all-walists (vl-nowarn-all-wirealists mods)))
   (reportcard     vl-reportcard-p))
  :guard (subsetp-equal (redundant-list-fix x)
                        (redundant-list-fix mods))
  :returns (new-reportcard vl-reportcard-p
                        :hyp (and (force (vl-modulelist-p x))
                                  (force (vl-reportcard-p reportcard))))
  (b* (((when (atom x))
        reportcard)
       (mod1    (car x))
       (walist1 (cdr (hons-get (vl-module->name mod1) all-walists)))
       (reportcard (us-check-port-bits mod1 walist1 reportcard)))
    (us-modulelist-check-port-bits (cdr x) mods all-walists reportcard))
  :prepwork ((local (defthm car-when-vl-modulelist-p-under-iff
                      (implies (vl-modulelist-p x)
                               (iff (car x)
                                    (consp x)))))))



(defsection us-db-p

; Use-Set Database (for an individual module).  Associates wire names to
; bit-sets that tell us whether the wire is used, set, falsely used, and
; falsely set.
;
; Initially each wire is bound to the empty set (i.e., not used, not set, not
; falsely used, not falsely set).  But eventually we may set these bits as we
; infer that the wire is used/set.

  (defval *us-empty* 0)

  (defval *us-truly-usedp*       0)
  (defval *us-truly-setp*        1)
  (defval *us-falsely-usedp*     2)
  (defval *us-falsely-setp*      3)

  ;; truly used/set in any superior module?
  (defval *us-truly-used-abovep* 4)
  (defval *us-truly-set-abovep*  5)

  (defval *us-above-mask* (acl2::bitset-list* *us-truly-set-abovep*
                                                *us-truly-used-abovep*
                                                0))

  (defalist us-db-p (x)
    :key (vl-emodwire-p x)
    :val (natp x)
    :keyp-of-nil nil
    :valp-of-nil nil))


(defalist us-dbalist-p (x)

; A 'dbalist' is a (typically fast) alist mapping module names to their Use-Set
; Databases (us-db-ps).  This is used so that we can look up whether the ports
; of submodules are used/set when we are processing module instances.

  :key (stringp x)
  :val (us-db-p x)
  :keyp-of-nil nil
  :valp-of-nil t)



(defsection us-initialize-db

; We create an initial us-db-p from a wire alist, binding each wire to the
; empty set.

  (define sum-lens (x)
    ;; We use this to get the initial size for each us-db-p.  This drastically
    ;; reduces memory usage from rehashing.
    (if (atom x)
        0
      (+ (len (car x))
         (sum-lens (cdr x)))))

  (define us-initialize-db-aux1 ((wires vl-emodwirelist-p) acc)
    :parents (us-initialize-db)
    :short "Bind each wire in a list to the empty set."
    :returns (acc us-db-p :hyp (and (force (vl-emodwirelist-p wires))
                                    (force (us-db-p acc))))
    (if (atom wires)
        acc
      (hons-acons (car wires) 0 (us-initialize-db-aux1 (cdr wires) acc))))

  (define us-initialize-db-exec ((walist vl-wirealist-p) acc)
    :parents (us-initialize-db)
    :short "Bind each wire in a wirealist to the empty set."
    :returns (acc us-db-p :hyp (and (force (vl-wirealist-p walist))
                                    (force (us-db-p acc))))
    (if (atom walist)
        acc
      (let ((acc (us-initialize-db-aux1 (cdar walist) acc)))
        (us-initialize-db-exec (cdr walist) acc))))

  (define us-initialize-db ((walist vl-wirealist-p))
    :returns (db us-db-p :hyp :fguard)
    (us-initialize-db-exec walist (- (sum-lens walist)
                                     (len walist)))))




(defsection us-mark-wires

; (US-MARK-WIRES MASK WIRES DB WARNINGS ELEM) --> (MV WARNINGS DB)
;
; This is our main updating function for the database.
;
;   MASK     - a bit set
;   WIRES    - a list of wires
;   DB       - the database which we update
;   WARNINGS - warnings accumulator which we update
;   ELEM     - semantically irrelevant, context for warning messages
;
; This is our main database updating function.  We union MASK into the bit-set
; for each wire in WIRES.

  (define us-mark-wire ((mask     natp)
                        (wire     vl-emodwire-p)
                        (db       us-db-p)
                        (warnings vl-warninglist-p)
                        (elem     vl-modelement-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p          :hyp :fguard))
    (b* ((curr (hons-get wire db))
         ((unless curr)
          (mv (warn :type :use-set-fudging
                    :msg "~a0: expected use-set db entry for ~x1."
                    :args (list elem wire))
              db))
         (val (acl2::bitset-union mask (cdr curr)))
         ;; dumb optimization: avoid consing if not necessary
         (db (if (= val (cdr curr))
                 db
               (hons-acons wire val db))))
      (mv (ok) db)))

  (define us-mark-wires ((mask     natp)
                         (wires    vl-emodwirelist-p)
                         (db       us-db-p)
                         (warnings vl-warninglist-p)
                         (elem     vl-modelement-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p          :hyp :fguard))
    (b* (((when (atom wires))
          (mv (ok) db))
         ((mv warnings db)
          (us-mark-wire mask (car wires) db warnings elem)))
      (us-mark-wires mask (cdr wires) db warnings elem)))

; Handy wrappers that hide all this bit-masking nonsense:

  (defmacro us-mark-wires-truly-used (wires db warnings elem)
    (let ((mask (acl2::bitset-singleton *us-truly-usedp*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem)))

  (defmacro us-mark-wires-truly-set (wires db warnings elem)
    (let ((mask (acl2::bitset-singleton *us-truly-setp*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem)))

  (defmacro us-mark-wires-truly-used/set (wires db warnings elem)
    (let* ((mask (acl2::bitset-list *us-truly-usedp* *us-truly-setp*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem)))


  (defmacro us-mark-wires-falsely-used (wires db warnings elem)
    (let ((mask (acl2::bitset-singleton *us-falsely-usedp*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem)))

  (defmacro us-mark-wires-falsely-set (wires db warnings elem)
    (let ((mask (acl2::bitset-singleton *us-falsely-setp*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem)))


  (defmacro us-mark-wires-used-above (wires db warnings elem)
    (let ((mask (acl2::bitset-singleton *us-truly-used-abovep*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem)))

  (defmacro us-mark-wires-set-above (wires db warnings elem)
    (let ((mask (acl2::bitset-singleton *us-truly-set-abovep*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem)))

  (defmacro us-mark-wires-used/set-above (wires db warnings elem)
    (let ((mask (acl2::bitset-list *us-truly-set-abovep* *us-truly-used-abovep*)))
      `(us-mark-wires ,mask ,wires ,db ,warnings ,elem))))


(define us-mark-toplevel-port-bits
  :short "We mark all the port bits for the top-level modules as either used
          from above, set from above, or both, based on their direction."
  ((x        vl-portdecllist-p)
   (walist   vl-wirealist-p)
   (db       us-db-p)
   (warnings vl-warninglist-p))
  :returns (mv (warnings vl-warninglist-p)
               (db       us-db-p          :hyp :fguard))
  :verify-guards nil
  (b* (((when (atom x))
        (mv (ok) db))
       ((mv warnings db)
        (us-mark-toplevel-port-bits (cdr x) walist db warnings))
       (entry (hons-get (vl-portdecl->name (car x)) walist))
       (wires (cdr entry))
       ((unless entry)
        (b* ((w (make-vl-warning :type :vl-bad-portdecl
                                 :msg "~a0: no corresponding wires."
                                 :args (list (car x))
                                 :fatalp t
                                 :fn 'us-mark-toplevel-port-bits-for-module)))
          (mv (cons w warnings) db)))
       ((mv warnings db)
        (case (vl-portdecl->dir (car x))
          (:vl-input  (us-mark-wires-set-above wires db warnings (car x)))
          (:vl-output (us-mark-wires-used-above wires db warnings (car x)))
          (:vl-inout  (us-mark-wires-used/set-above wires db warnings (car x)))
          (otherwise  (prog2$ (impossible)
                              (mv warnings db))))))
    (mv warnings db))
  ///
  (verify-guards us-mark-toplevel-port-bits))



; Performance note.  I experimented with sorting wires before inserting them
; into the database, but directly marking them as we encounter them seems to
; perform better.

(defsection us-mark-wires-for-gateinstlist

; Gate instances are straightforward.  The argresolve transform should mark all
; arguments with their directions, so we know whether they are inputs, outputs,
; or inouts.  We mark any wires being connected to inputs as truly used, and
; any wires connected to outputs as truly set.

  (define us-mark-wires-for-gateinst-arg
    ((x        vl-plainarg-p)
     (walist   vl-wirealist-p)
     (db       us-db-p)
     (warnings vl-warninglist-p)
     (elem     vl-modelement-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db us-db-p :hyp :fguard))
    (b* (((vl-plainarg x) x)
         ((unless x.expr)
          ;; Fine, there's nothing to do.
          (mv (ok) db))

         (warnings (if x.dir
                       (ok)
                     (warn :type :use-set-fudging
                           :msg "~a0: argument ~a1 has no direction; treating it as inout."
                           :args (list elem x))))

         (dir                  (or x.dir :vl-inout))
         ((mv warnings2 wires) (vl-expr-allwires x.expr walist))
         (warnings             (append warnings2 warnings)))
      (case dir
        (:vl-input  (us-mark-wires-truly-used wires db warnings elem))
        (:vl-output (us-mark-wires-truly-set wires db warnings elem))
        (otherwise  (us-mark-wires-truly-used/set wires db warnings elem)))))

  (define us-mark-wires-for-gateinst-args ((x        vl-plainarglist-p)
                                           (walist   vl-wirealist-p)
                                           (db       us-db-p)
                                           (warnings vl-warninglist-p)
                                           (elem     vl-modelement-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db)
          (us-mark-wires-for-gateinst-arg (car x) walist db warnings elem)))
      (us-mark-wires-for-gateinst-args (cdr x) walist db warnings elem)))

  (define us-mark-wires-for-gateinst ((x        vl-gateinst-p)
                                      (walist   vl-wirealist-p)
                                      (db       us-db-p)
                                      (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((vl-gateinst x) x))
      (us-mark-wires-for-gateinst-args x.args walist db warnings x)))

  (define us-mark-wires-for-gateinstlist ((x        vl-gateinstlist-p)
                                          (walist   vl-wirealist-p)
                                          (db       us-db-p)
                                          (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db) (us-mark-wires-for-gateinst (car x) walist db warnings)))
      (us-mark-wires-for-gateinstlist (cdr x) walist db warnings))))


(defsection us-mark-wires-for-assignlist

; Assignments are straightforward.  We just mark all wires on the RHS as being
; truly used, and all wires on the LHS as being truly set.  This is easy to fool
; with things like:
;
;    assign foo = foo;
;    assign foo = bar & 0;
;    assign foo = bar & ~bar;
;
; etc., but it seems hard to avoid this sort of problem unless we take a much
; more sophisticated approach, e.g., doing real symbolic simulations and using
; something like aig-vars to compute the dependencies.

  (define us-mark-wires-for-assign ((x        vl-assign-p)
                                    (walist   vl-wirealist-p)
                                    (db       us-db-p)
                                    (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((vl-assign x) x)
         ((mv warnings1 rhs-wires) (vl-expr-allwires x.expr walist))
         ((mv warnings2 lhs-wires) (vl-expr-allwires x.lvalue walist))
         (warnings (append warnings1 warnings2 warnings))
         ((mv warnings db) (us-mark-wires-truly-used rhs-wires db warnings x))
         ((mv warnings db) (us-mark-wires-truly-set lhs-wires db warnings x)))
      (mv warnings db)))

  (define us-mark-wires-for-assignlist ((x        vl-assignlist-p)
                                        (walist   vl-wirealist-p)
                                        (db       us-db-p)
                                        (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db) (us-mark-wires-for-assign (car x) walist db warnings))
         ((mv warnings db) (us-mark-wires-for-assignlist (cdr x) walist db warnings)))
      (mv warnings db))))


(defsection us-mark-wires-for-vardecllist

  (define us-mark-wires-for-vardecl
    :short "If a net is declared to be a supply0 or a supply1, then we want to
            think of it as driven."
    ((x        vl-vardecl-p)
     (walist   vl-wirealist-p)
     (db       us-db-p)
     (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((vl-vardecl x) x)
         ((unless (and (eq (vl-datatype-kind x.type) :vl-nettype)
                       (member (vl-nettype->name x.type) '(:vl-supply0 :vl-supply1))))
          (mv (ok) db))

         (entry (hons-get x.name walist))
         (wires (cdr entry))
         ((unless entry)
          (mv (fatal :type :vl-bad-vardecl
                     :msg "~a0: no corresponding wires."
                     :args (list (car x)))
              db))

         ((mv warnings db) (us-mark-wires-truly-set wires db warnings x)))
      (mv warnings db)))

  (define us-mark-wires-for-vardecllist ((x        vl-vardecllist-p)
                                         (walist   vl-wirealist-p)
                                         (db       us-db-p)
                                         (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db) (us-mark-wires-for-vardecl (car x) walist db warnings))
         ((mv warnings db) (us-mark-wires-for-vardecllist (cdr x) walist db warnings)))
      (mv warnings db))))


(define vl-evatom-allwires ((x vl-evatom-p)
                            (walist vl-wirealist-p))
  :returns (mv (warnings vl-warninglist-p)
               (wires    vl-emodwirelist-p :hyp :fguard))
  (vl-expr-allwires (vl-evatom->expr x) walist))

(define vl-evatomlist-allwires ((x      vl-evatomlist-p)
                                (walist vl-wirealist-p))
  :returns (mv (warnings vl-warninglist-p)
               (wires    vl-emodwirelist-p :hyp :fguard))
  (b* (((when (atom x))
        (mv nil nil))
       ((mv car-warnings car-wires) (vl-evatom-allwires (car x) walist))
       ((mv cdr-warnings cdr-wires) (vl-evatomlist-allwires (cdr x) walist)))
    (mv (append-without-guard car-warnings cdr-warnings)
        (append-without-guard car-wires cdr-wires))))

(define vl-eventcontrol-allwires ((x      vl-eventcontrol-p)
                                  (walist vl-wirealist-p))
  :returns (mv (warnings vl-warninglist-p)
               (wires    vl-emodwirelist-p :hyp :fguard))
  (vl-evatomlist-allwires (vl-eventcontrol->atoms x) walist))

(define vl-repeateventcontrol-allwires ((x      vl-repeateventcontrol-p)
                                        (walist vl-wirealist-p))
  :returns (mv (warnings vl-warninglist-p)
               (wires    vl-emodwirelist-p :hyp :fguard))
  (b* (((vl-repeateventcontrol x) x)
       ((mv warnings1 wires1) (vl-expr-allwires x.expr walist))
       ((mv warnings2 wires2) (vl-eventcontrol-allwires x.ctrl walist)))
    (mv (append-without-guard warnings1 warnings2)
        (append-without-guard wires1 wires2))))

(define vl-delayoreventcontrol-allwires ((x      vl-delayoreventcontrol-p)
                                         (walist vl-wirealist-p))
  :returns (mv (warnings vl-warninglist-p)
               (wires    vl-emodwirelist-p :hyp :fguard))
  (b* ((x (vl-delayoreventcontrol-fix x)))
    (case (tag x)
      (:vl-delaycontrol (vl-expr-allwires (vl-delaycontrol->value x) walist))
      (:vl-eventcontrol (vl-eventcontrol-allwires x walist))
      (otherwise        (vl-repeateventcontrol-allwires x walist)))))

(defines us-mark-wires-for-stmt

  (define us-mark-wires-for-stmt ((x        vl-stmt-p)
                                  (walist   vl-wirealist-p)
                                  (db       us-db-p)
                                  (warnings vl-warninglist-p)
                                  (elem     vl-modelement-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    :measure (vl-stmt-count x)
    :verify-guards nil
    (b* ((x (vl-stmt-fix x))
         (warnings (vl-warninglist-fix warnings))

         ((when (vl-atomicstmt-p x))
          (case (tag (vl-stmt-kind x))
            ;; - Nothing to do for null statements.
            ;; - Don't think we want to do anything for eventtriggerstmts?
            ;; - Don't think we want to do anything for deassign statements?
            (:vl-assignstmt
             (b* (((vl-assignstmt x) x)
                  ((mv warnings1 rhs-wires) (vl-expr-allwires x.expr walist))
                  ((mv warnings2 lhs-wires) (vl-expr-allwires x.lvalue walist))
                  (warnings (append warnings1 warnings2 warnings))
                  ((mv warnings db) (us-mark-wires-truly-used rhs-wires db warnings elem))
                  ((mv warnings db) (us-mark-wires-truly-set lhs-wires db warnings elem)))
               (mv warnings db)))
            (:vl-enablestmt
             (mv (warn :type :use-set-fudging
                       :msg "~a0: Ignoring ~a1 since we don't currently support tasks/functions."
                       :args (list elem x))
                 db))
            (otherwise
             (mv warnings db))))

         ;; Mark all use/set info for sub-statements.
         ((mv warnings db)
          (us-mark-wires-for-stmtlist (vl-compoundstmt->stmts x)
                                      walist db warnings elem))

         ((when (vl-casestmt-p x))
          ;; Additionally mark all test expression wires as used since they're
          ;; deciding which branch to follow.
          (b* (((vl-casestmt x) x)
               (exprs                (cons x.test (flatten (alist-keys x.caselist))))
               ((mv warnings1 wires) (vl-exprlist-allwires exprs walist))
               (warnings             (append-without-guard warnings1 warnings)))
            (us-mark-wires-truly-used wires db warnings elem)))

         ((when (vl-ifstmt-p x))
          ;; Additionally mark condition's wires as truly used since they're
          ;; deciding which branch to follow.
          (b* (((vl-ifstmt x) x)
               ((mv warnings1 wires) (vl-expr-allwires x.condition walist))
               (warnings             (append-without-guard warnings1 warnings)))
            (us-mark-wires-truly-used wires db warnings elem)))

         ((when (vl-foreverstmt-p x))
          ;; Nothing extra to do.
          (mv warnings db))

         ((when (vl-waitstmt-p x))
          ;; Additionally mark condition's wires as true, since they're used to
          ;; decide when to execute the body
          (b* (((vl-waitstmt x) x)
               ((mv warnings1 wires) (vl-expr-allwires x.condition walist))
               (warnings             (append-without-guard warnings1 warnings)))
            (us-mark-wires-truly-used wires db warnings elem)))

          ((when (vl-repeatstmt-p x))
           ;; Additionally mark the condition's wires as used, even though there
           ;; probably aren't any.
           (b* (((vl-repeatstmt x) x)
                ((mv warnings1 wires) (vl-expr-allwires x.condition walist))
                (warnings             (append-without-guard warnings1 warnings)))
             (us-mark-wires-truly-used wires db warnings elem)))

          ((when (vl-whilestmt-p x))
           ;; Additionally mark condition's wires as used
           (b* (((vl-whilestmt x) x)
                ((mv warnings1 wires) (vl-expr-allwires x.condition walist))
                (warnings             (append-without-guard warnings1 warnings)))
             (us-mark-wires-truly-used wires db warnings elem)))

          ((when (vl-forstmt-p x))
           (b* (((vl-forstmt x) x)
                ((mv warnings1 lhs1-wires) (vl-expr-allwires x.initlhs walist))
                ((mv warnings2 lhs2-wires) (vl-expr-allwires x.nextlhs walist))
                ((mv warnings3 rhs1-wires) (vl-expr-allwires x.initrhs walist))
                ((mv warnings4 rhs2-wires) (vl-expr-allwires x.nextrhs walist))
                ((mv warnings5 test-wires) (vl-expr-allwires x.test walist))
                (warnings (append-without-guard warnings1 warnings2 warnings3
                                                warnings4 warnings5 warnings))
                ((mv warnings db) (us-mark-wires-truly-set lhs1-wires db warnings elem))
                ((mv warnings db) (us-mark-wires-truly-set lhs2-wires db warnings elem))
                ((mv warnings db) (us-mark-wires-truly-used rhs1-wires db warnings elem))
                ((mv warnings db) (us-mark-wires-truly-used rhs2-wires db warnings elem))
                ((mv warnings db) (us-mark-wires-truly-used test-wires db warnings elem)))
             (mv warnings db)))

          ((when (vl-blockstmt-p x))
           (b* (((vl-blockstmt x) x)
                ((when x.decls)
                 (mv (warn :type :use-set-fudging
                           :msg "~a0: block statements with declarations are ~
                                 not really supported; we'll get the wrong ~
                                 use/set information for local declarations ~
                                 in block ~s1."
                           :args (list elem x.name))
                     db)))
             (mv warnings db)))

          ((when (vl-timingstmt-p x))
           (b* (((vl-timingstmt x) x)
                ((mv warnings1 wires) (vl-delayoreventcontrol-allwires x.ctrl walist))
                (warnings             (append-without-guard warnings1 warnings)))
             (us-mark-wires-truly-used wires db warnings elem))))

      (impossible)
      (mv warnings db)))

  (define us-mark-wires-for-stmtlist ((x        vl-stmtlist-p)
                                      (walist   vl-wirealist-p)
                                      (db       us-db-p)
                                      (warnings vl-warninglist-p)
                                      (elem     vl-modelement-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    :measure (vl-stmtlist-count x)
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db) (us-mark-wires-for-stmt (car x) walist db warnings elem)))
      (us-mark-wires-for-stmtlist (cdr x) walist db warnings elem)))
  ///
  (verify-guards us-mark-wires-for-stmt
    :hints(("Goal" :in-theory (enable vl-atomicstmt-p)))))


(defsection us-mark-wires-for-alwayslist

  (define us-mark-wires-for-always ((x        vl-always-p)
                                    (walist   vl-wirealist-p)
                                    (db       us-db-p)
                                    (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (us-mark-wires-for-stmt (vl-always->stmt x) walist db warnings x))

  (define us-mark-wires-for-alwayslist ((x        vl-alwayslist-p)
                                        (walist   vl-wirealist-p)
                                        (db       us-db-p)
                                        (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db) (us-mark-wires-for-always (car x) walist db warnings))
         ((mv warnings db) (us-mark-wires-for-alwayslist (cdr x) walist db warnings)))
      (mv warnings db))))



(defsection us-mark-wires-for-initiallist

; Originally I didn't look at "initial" statements at all, and it still seems a
; little weird to consider them.  (After all, any use of initial statements is
; sort of an incorrect mixing of simulation and rtl constructs.)  But, for the
; purposes of the linter, I decided to count them because otherwise we get some
; warnings that "seem stupid" to the person reading the warning.  That is, we
; see messages that some register is used but never set, when clearly it is set
; right at the beginning of the simulation.  While this is fairly rare, it is
; probably still worth filtering out.

  (define us-mark-wires-for-initial ((x        vl-initial-p)
                                     (walist   vl-wirealist-p)
                                     (db       us-db-p)
                                     (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (us-mark-wires-for-stmt (vl-initial->stmt x) walist db warnings x))

  (define us-mark-wires-for-initiallist ((x        vl-initiallist-p)
                                         (walist   vl-wirealist-p)
                                         (db       us-db-p)
                                         (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db) (us-mark-wires-for-initial (car x) walist db warnings))
         ((mv warnings db) (us-mark-wires-for-initiallist (cdr x) walist db warnings)))
      (mv warnings db))))


(defsection us-mark-false-inouts

; (US-MARK-FALSE-INOUTS PORTDECLS WALIST DB WARNINGS) --> (MV WARNINGS DB)
;
; We update DB by marking any unused inputs as falsely used, and any unset
; outputs as falsely set.  This must happen as a "final pass" after determining
; all of the ordinary set/used wires in the module.

  (define us-mark-false-inouts-for-portdecl-wires
    ((wires    vl-emodwirelist-p "all wires from a portdecl")
     (dir      vl-direction-p    "dir of this portdecl")
     (db       us-db-p           "use-set database for this module (may be extended)")
     (warnings vl-warninglist-p  "warnings accumulator (may be extended)")
     (elem     vl-modelement-p   "context for warnings"))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    :verify-guards nil
    (b* (((when (atom wires))
          (mv (ok) db))

         ((mv warnings db)
          (us-mark-false-inouts-for-portdecl-wires (cdr wires) dir db warnings elem))

         (wire1  (car wires))
         (lookup (hons-get wire1 db))
         ((unless lookup)
          (mv (warn :type :use-set-fudging
                    :msg "~a0: expected a database binding for ~s1.  Assuming ~
                          it is not a false input/output."
                    :args (list elem wire1))
              db))

         ((mv warnings db)
          (if (and (or (eq dir :vl-input)
                       (eq dir :vl-inout))
                   (not (acl2::bitset-memberp *us-truly-usedp* (cdr lookup))))
              ;; Input that isn't truly used == falsely used
              (us-mark-wire (acl2::bitset-singleton *us-falsely-usedp*)
                            wire1 db warnings elem)
            (mv warnings db)))

         ((mv warnings db)
          (if (and (or (eq dir :vl-output)
                       (eq dir :vl-inout))
                   (not (acl2::bitset-memberp *us-truly-setp* (cdr lookup))))
              ;; Output that isn't truly set == falsely set
              (us-mark-wire (acl2::bitset-singleton *us-falsely-setp*)
                            wire1 db warnings elem)
            (mv warnings db))))

      (mv warnings db))
    ///
    (verify-guards us-mark-false-inouts-for-portdecl-wires))


  (define us-mark-false-inouts-for-portdecl ((x        vl-portdecl-p)
                                             (db       us-db-p)
                                             (walist   vl-wirealist-p)
                                             (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((vl-portdecl x) x)
         (lookup (hons-get x.name walist))
         ((unless lookup)
          (mv (warn :type :use-set-fudging
                    :msg "~a0: expected wire-alist binding for ~s1.  Assuming ~
                         its wires are not false input/outputs."
                    :args (list x x.name))
              db)))
      (us-mark-false-inouts-for-portdecl-wires (cdr lookup) x.dir db warnings x)))

  (define us-mark-false-inouts  ((x        vl-portdecllist-p)
                                 (db       us-db-p)
                                 (walist   vl-wirealist-p)
                                 (warnings vl-warninglist-p))
    :returns (mv (warnings vl-warninglist-p)
                 (db       us-db-p :hyp :fguard))
    (b* (((when (atom x))
          (mv (ok) db))
         ((mv warnings db)
          (us-mark-false-inouts-for-portdecl (car x) db walist warnings)))
      (us-mark-false-inouts (cdr x) db walist warnings))))



; We make a US-NOTE for every module instance connection:

(defaggregate us-note
  (submod   ; the submodule being instanced
   formals  ; the particular wires (port bits from submod) that this note pertains to
   actuals  ; the actual wires that are connected
   )
  :tag :us-note
  :legiblep nil
  :require ((stringp-of-us-note->submod
             (stringp submod)
             :rule-classes :type-prescription)
            (vl-emodwirelist-p-of-us-note->formals
             (vl-emodwirelist-p formals))
            (vl-emodwirelist-p-of-us-note->actuals
             (vl-emodwirelist-p actuals))))

(deflist us-notelist-p (x)
  (us-note-p x)
  :guard t
  :elementp-of-nil nil)

(defalist us-notealist-p (x)
  :key (stringp x)
  :val (us-notelist-p x)
  :keyp-of-nil nil
  :valp-of-nil t)



(defsection us-mark-wires-for-modinst-lvalue-arg

; Handler for module instance arguments whose expressions look like lvalues,
; and hence whose bits can be lined up with the port expression.

  (defund us-mark-wires-for-modinst-lvalue-arg
    (actual-bits ; bits for the argument
     formal-bits ; bits for the submodule's port; matches len of actual-bits
     sub-db      ; db for the submodule
     db          ; db for the superior module                    (may be extended)
     warnings    ; warnings accumulator for the superior module  (may be extended)
     inst        ; context for warnings and notes
     notes       ; accumulator for notes                         (may be extended)
     )
    "Returns (MV WARNINGS DB NOTES)"
    (declare (xargs :guard (and (vl-emodwirelist-p actual-bits)
                                (vl-emodwirelist-p formal-bits)
                                (same-lengthp actual-bits formal-bits)
                                (us-db-p sub-db)
                                (us-db-p db)
                                (vl-warninglist-p warnings)
                                (vl-modinst-p inst)
                                (us-notelist-p notes))
                    :verify-guards nil))

    ;; We recursively process each actual-bit/formal-bit pair.
    (b* (((when (atom actual-bits))
          (mv warnings db notes))

         ((mv warnings db notes)
          (us-mark-wires-for-modinst-lvalue-arg (cdr actual-bits) (cdr formal-bits)
                                                sub-db db warnings inst notes))

         (actual1 (car actual-bits))
         (formal1 (car formal-bits))
         (formal1-look (hons-get formal1 sub-db))
         ((unless formal1-look)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: expected a binding for formal bit ~s1; not ~
                         inferring any use/set information for ~s2."
                   :args (list inst formal1 actual1)
                   :fn 'us-mark-wires-for-modinst-lvalue-arg)))
            (mv (cons w warnings) db notes)))

         ;; We just merge in the mask from formal1.  If the formal is
         ;; truly/falsely used, then this marks the actual as being
         ;; truly/falsely used.  If the formal is truly/falsely set, this marks
         ;; the actual as being truly/falsely set.
         (formal1-mask (cdr formal1-look))
         ;; Strip out any used above/below info
         (formal1-mask (acl2::bitset-difference formal1-mask *us-above-mask*))
         ((mv warnings db)
          (us-mark-wire formal1-mask actual1 db warnings inst))
         (note (make-us-note :submod  (vl-modinst->modname inst)
                             :formals (list formal1)
                             :actuals (list actual1))))
      (mv warnings db (cons note notes))))

  (defthm us-mark-wires-for-modinst-lvalue-arg-basics
    (implies (and (force (vl-emodwirelist-p actual-bits))
                  (force (vl-emodwirelist-p formal-bits))
                  (force (same-lengthp actual-bits formal-bits))
                  (force (us-db-p sub-db))
                  (force (us-db-p db))
                  (force (vl-warninglist-p warnings))
                  (force (vl-modinst-p inst))
                  (force (us-notelist-p notes)))
             (let ((ret (us-mark-wires-for-modinst-lvalue-arg actual-bits formal-bits
                                                              sub-db db warnings inst
                                                              notes)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret))
                    (us-notelist-p (mv-nth 2 ret)))))
    :hints(("Goal" :in-theory (enable us-mark-wires-for-modinst-lvalue-arg))))

  (verify-guards us-mark-wires-for-modinst-lvalue-arg))




(defsection us-mark-wires-for-modinst-rvalue-arg

; Handler for module instance arguments whose expressions do NOT look like
; lvalues.
;
; We use this when expressions like "foo + bar" are given to ports.  These
; expressions are tricky because we can't proceed on a bit-by-bit basis.
; (Well, there might be some cases where we *could* go bit-by-bit if we were
; smart enough, e.g., foo & bar, but this seems too hard.)
;
; Lets suppose that "foo + bar" is hooked to port[3:0] or something.
;
; It would be really, really strange if any of port[3:0] were set in the
; submodule, since this would mean that the wire was being driven from both
; sides, e.g.,:
;
;                               ||
;                ______         ||         ___
;      foo  ----|      \        ||        /   |
;               |  "+"  )------port------(    |----- [...]
;      bar  ----|______/        ||        \___|
;                               ||
;                         super || sub
;                               ||
;
; We cause a warning if we see this sort of thing, and we don't infer that the
; wires of foo/bar are driven in this situation because it seems like the
; actual wires being driven "from the right" are something internal to the +
; operation that is being generated.
;
; On the other hand, it seems valid to ask whether port is being used for
; anything.  If any of port's bits are being used, we'll mark all the wires for
; foo and bar as used.  Similarly, if port's bits are only falsely used, we'll
; mark foo and bar's bits as falsely used.

  (defund us-rvalue-mask (bits sub-db warnings elem)
    ;; Union the masks for all bits.
    "Returns (MV WARNINGS MASK)"
    (declare (xargs :guard (and (vl-emodwirelist-p bits)
                                (us-db-p sub-db)
                                (vl-warninglist-p warnings)
                                (vl-modelement-p elem))))
    (b* (((when (atom bits))
          (mv warnings 0))
         ((mv warnings cdr-mask)
          (us-rvalue-mask (cdr bits) sub-db warnings elem))
         (lookup (hons-get (car bits) sub-db))
         ((unless lookup)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: expected database entry for port bit ~s1.  ~
                         Assuming it isn't used/set in the submodule"
                   :args (list elem (car bits))
                   :fn 'us-rvalue-mask)))
            (mv (cons w warnings) cdr-mask)))
         (car-mask (cdr lookup)))
      (mv warnings (acl2::bitset-union car-mask cdr-mask))))

  (defthm us-rvalue-mask-basics
    (implies (and (force (vl-emodwirelist-p bits))
                  (force (us-db-p sub-db))
                  (force (vl-warninglist-p warnings))
                  (force (vl-modelement-p elem)))
             (let ((ret (us-rvalue-mask bits sub-db warnings elem)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (natp (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-rvalue-mask))))



  (defund us-mark-wires-for-modinst-rvalue-arg
    (expr        ; the "actual" expression being connected to the port
     formal-bits ; the bits of the formal, in msb-first order
     sub-db      ; db for the submodule
     db       ; db for the superior module                   (may be extended)
     walist   ; wire alist for the superior module
     warnings ; warnings accumulator for the superior module (may be extended)
     inst     ; context for warnings and notes
     notes    ; accumulator for notes                        (may be extended)
     )
    "Returns (MV WARNINGS DB NOTES)"
    (declare (xargs :guard (and (vl-expr-p expr)
                                (vl-emodwirelist-p formal-bits)
                                (us-db-p sub-db)
                                (us-db-p db)
                                (vl-wirealist-p walist)
                                (vl-warninglist-p warnings)
                                (vl-modinst-p inst)
                                (us-notelist-p notes))))

    (b* (((mv warnings1 expr-wires) (vl-expr-allwires expr walist))
         (warnings (append warnings1 warnings))

         ;; Union of the masks for all formals.
         ((mv warnings mask) (us-rvalue-mask formal-bits sub-db warnings inst))
         ;; Filter out any used above/below info.
         (mask (acl2::bitset-difference mask *us-above-mask*))

         (warnings
          (cond
           ((acl2::bitset-memberp *us-truly-setp* mask)
            (cons (make-vl-warning
                   :type :use-set-trainwreck
                   :msg "~a0: argument ~a1, which is not shaped like an ~
                           lvalue, is connected to a port that is being ~
                           driven within the submodule.  This seems like ~
                           the port is being driven from both sides, which ~
                           might be terrible.  Port bits: ~&2."
                   :args (list inst expr
                               (vl-verilogify-emodwirelist formal-bits))
                   :fn 'us-mark-wires-for-modinst-rvalue-arg)
                  warnings))
           ((acl2::bitset-memberp *us-falsely-setp* mask)
            (cons (make-vl-warning
                   :type :use-set-future-trainwreck
                   :msg "~a0: argument ~a1, which is not shaped like an ~
                           lvalue, is connected to a port that is declared as ~
                           an inout or output.  This is not actually a ~
                           problem yet because the submodule is not actually ~
                           driving this output.  Port bits: ~&2."
                   :args (list inst expr
                               (vl-verilogify-emodwirelist formal-bits))
                   :fn 'us-mark-wires-for-modinst-rvalue-arg)
                  warnings))
           (t
            warnings)))

         (mask (acl2::bitset-delete mask *us-truly-setp*))
         (mask (acl2::bitset-delete mask *us-falsely-setp*))
         ((mv warnings db)
          (us-mark-wires mask expr-wires db warnings inst))

         (note (make-us-note :submod (vl-modinst->modname inst)
                             :formals formal-bits
                             :actuals expr-wires)))
      (mv warnings db (cons note notes))))

  (defthm us-mark-wires-for-modinst-rvalue-arg-basics
    (implies (and (force (vl-expr-p expr))
                  (force (vl-emodwirelist-p formal-bits))
                  (force (us-db-p sub-db))
                  (force (us-db-p db))
                  (force (vl-wirealist-p walist))
                  (force (vl-warninglist-p warnings))
                  (force (vl-modinst-p inst))
                  (force (us-notelist-p notes)))
             (let ((ret (us-mark-wires-for-modinst-rvalue-arg expr formal-bits
                                                              sub-db db walist
                                                              warnings inst notes)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret))
                    (us-notelist-p (mv-nth 2 ret)))))
    :hints(("Goal" :in-theory (enable us-mark-wires-for-modinst-rvalue-arg)))))



(defsection us-mark-wires-for-modinst-arg

  (defund us-mark-wires-for-modinst-arg
    (arg         ; the plainarg being connected to the port
     formal-bits ; the bits of the formal, in msb-first order
     sub-db      ; db for the submodule
     db          ; db for the superior module                   (may be extended)
     walist      ; wire alist for the superior module
     warnings    ; warnings accumulator for the superior module (may be extended)
     inst        ; context for warnings and notes
     notes       ; accumulator for notes                        (may be extended)
     )
    "Returns (MV WARNINGS DB NOTES)"
    (declare (xargs :guard (and (vl-plainarg-p arg)
                                (vl-emodwirelist-p formal-bits)
                                (us-db-p sub-db)
                                (us-db-p db)
                                (vl-wirealist-p walist)
                                (vl-warninglist-p warnings)
                                (vl-modinst-p inst)
                                (us-notelist-p notes))))
    (b* ((expr (vl-plainarg->expr arg))
         ((unless expr)
          ;; Okay, nothing to do.
          (mv warnings db notes))
         ((unless (vl-expr-lvaluep expr))
          (us-mark-wires-for-modinst-rvalue-arg expr formal-bits
                                                sub-db db walist
                                                warnings inst notes))
         ((mv successp warnings expr-bits)
          (vl-msb-expr-bitlist expr walist warnings))
         (len-okp (same-lengthp expr-bits formal-bits))
         (warnings
          (cond ((not successp)
                 (cons (make-vl-warning
                        :type :use-set-fudging
                        :msg "~a0: failed to generate wires for ~a1; not ~
                              inferring any use/set information from this ~
                              port."
                        :args (list inst expr)
                        :fn 'us-mark-wires-for-modinst-arg)
                       warnings))
                ((not len-okp)
                 (cons (make-vl-warning
                        :type :use-set-fudging
                        :msg "~a0: width mismatch in port connection: expected ~x1 ~
                              bits (~s2) but found ~x3 bits in ~a4.  Not inferring ~
                              any use/set information from this port."
                        :args (list inst
                                    (len formal-bits)
                                    (vl-verilogify-emodwirelist formal-bits)
                                    (len expr-bits)
                                    expr)
                        :fn 'us-mark-wires-for-modinst-arg)
                       warnings))
                (t
                 ;; Okay, everything is fine.
                 warnings)))
         ((unless (and successp len-okp))
          (mv warnings db notes)))
      (us-mark-wires-for-modinst-lvalue-arg expr-bits formal-bits
                                            sub-db db warnings inst notes)))

  (defthm us-mark-wires-for-modinst-arg-basics
    (implies (and (force (vl-plainarg-p arg))
                  (force (vl-emodwirelist-p formal-bits))
                  (force (us-db-p sub-db))
                  (force (us-db-p db))
                  (force (vl-wirealist-p walist))
                  (force (vl-warninglist-p warnings))
                  (force (vl-modinst-p inst))
                  (force (us-notelist-p notes)))
             (let ((ret (us-mark-wires-for-modinst-arg arg formal-bits
                                                       sub-db db walist warnings
                                                       inst notes)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret))
                    (us-notelist-p (mv-nth 2 ret)))))
    :hints(("Goal" :in-theory (enable us-mark-wires-for-modinst-arg)))))



(defsection us-mark-wires-for-modinst-args

  (defund us-mark-wires-for-modinst-args
    (actuals  ; plainarglist of the actual exprs being passed to the modinst
     portpat  ; the port pattern for the submodule
     sub-db   ; db for the submodule being instanced
     db       ; db for the superior module  (may be extended)
     walist   ; wire alist for the superior module
     warnings ; warnings accumulator for the superior module (may be extended)
     inst     ; the instance itself (context for any warnings and notes)
     notes    ; accumulator for notes (may be extended)
     )
    "Returns (MV WARNINGS DB NOTES)"
    (declare (xargs :guard (and (vl-plainarglist-p actuals)
                                (vl-emodwirelistlist-p portpat)
                                (same-lengthp actuals portpat)
                                (us-db-p sub-db)
                                (us-db-p db)
                                (vl-wirealist-p walist)
                                (vl-warninglist-p warnings)
                                (vl-modinst-p inst)
                                (us-notelist-p notes))))
    (b* (((when (atom actuals))
          (mv warnings db notes))
         ((mv warnings db notes)
          (us-mark-wires-for-modinst-arg (car actuals) (car portpat) sub-db db walist warnings inst notes))
         ((mv warnings db notes)
          (us-mark-wires-for-modinst-args (cdr actuals) (cdr portpat) sub-db db walist warnings inst notes)))
      (mv warnings db notes)))

  (defthm us-mark-wires-for-modinst-args-basics
    (implies (and (force (vl-plainarglist-p actuals))
                  (force (vl-emodwirelistlist-p portpat))
                  (force (same-lengthp actuals portpat))
                  (force (us-db-p sub-db))
                  (force (us-db-p db))
                  (force (vl-wirealist-p walist))
                  (force (vl-warninglist-p warnings))
                  (force (vl-modinst-p inst))
                  (force (us-notelist-p notes)))
             (let ((ret (us-mark-wires-for-modinst-args actuals portpat
                                                        sub-db db walist warnings
                                                        inst notes)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret))
                    (us-notelist-p (mv-nth 2 ret)))))
    :hints(("Goal" :in-theory (enable us-mark-wires-for-modinst-args)))))



(defsection us-mark-wires-for-modinst

  (defund us-mark-wires-for-modinst
    (x           ; the modinst to process
     walist      ; walist for the current module
     db          ; db for the current module (may be extended)
     mods        ; all modules
     modalist    ; modalist for all modules
     dbalist     ; dbalist-p that should bind every submodule (due to dependency order traversal)
     all-walists ; precomputed walists for all mods
     warnings    ; warnings accumulator (may be extended)
     notes       ; notes accumulator (may be extended)
     )
    "Returns (MV WARNINGS DB NOTES)"
    (declare (xargs :guard (and (vl-modinst-p x)
                                (vl-wirealist-p walist)
                                (us-db-p db)
                                (vl-modulelist-p mods)
                                (equal modalist (vl-modalist mods))
                                (us-dbalist-p dbalist)
                                (equal all-walists (vl-nowarn-all-wirealists mods))
                                (vl-warninglist-p warnings)
                                (us-notelist-p notes))))
    (b* (((vl-modinst x) x)

         ((unless (and (not x.range)
                       (vl-paramargs-empty-p x.paramargs)
                       (eq (vl-arguments-kind x.portargs) :vl-arguments-plain)))
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: skipping this module instance because it has a ~
                       range, parameters, or unresolved arguments."
                   :args (list x x.modname)
                   :fn 'us-mark-wires-for-modinst)))
            (mv (cons w warnings) db notes)))

         (actuals (vl-arguments-plain->args x.portargs))

         (submod (vl-fast-find-module x.modname mods modalist))
         ((unless submod)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: skipping this module instance because module ~m1 ~
                       was not found."
                   :args (list x x.modname)
                   :fn 'us-mark-wires-for-modinst)))
            (mv (cons w warnings) db notes)))

         (sub-db-look (hons-get x.modname dbalist))
         (sub-db      (cdr sub-db-look))
         ((unless sub-db-look)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: skipping this module instance because the use-set ~
                       database for ~m1 was not found."
                   :args (list x x.modname)
                   :fn 'us-mark-wires-for-modinst)))
            (mv (cons w warnings) db notes)))

         (sub-walist-look (hons-get x.modname all-walists))
         (sub-walist      (cdr sub-walist-look))
         ((unless sub-walist-look)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: skipping this module instance because the wire ~
                       alist for ~m1 was not found."
                   :args (list x x.modname)
                   :fn 'us-mark-wires-for-modinst)))
            (mv (cons w warnings) db notes)))

         ((mv successp warnings1 portpat)
          (vl-portlist-msb-bit-pattern (vl-module->ports submod) sub-walist))
         (warnings (append-without-guard warnings1 warnings))
         ((unless successp)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: skipping this module instance because the port pattern ~
                       for ~m1 was not successfully generated."
                   :args (list x x.modname)
                   :fn 'us-mark-wires-for-modinst)))
            (mv (cons w warnings) db notes)))

         ((unless (same-lengthp portpat actuals))
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "~a0: skipping this module instance because it has ~x1 arguments ~
                       but we expected ~x2 arguments."
                   :args (list x (len actuals) (len portpat))
                   :fn 'us-mark-wires-for-modinst)))
            (mv (cons w warnings) db notes))))

      (us-mark-wires-for-modinst-args actuals portpat
                                      sub-db db walist
                                      warnings x notes)))

  (defthm us-mark-wires-for-modinst-basics
    (implies (and (force (vl-modinst-p x))
                  (force (vl-wirealist-p walist))
                  (force (us-db-p db))
                  (force (vl-modulelist-p mods))
                  (force (equal modalist (vl-modalist mods)))
                  (force (us-dbalist-p dbalist))
                  (force (equal all-walists (vl-nowarn-all-wirealists mods)))
                  (force (vl-warninglist-p warnings))
                  (force (us-notelist-p notes)))
             (let ((ret (us-mark-wires-for-modinst x walist db mods modalist dbalist all-walists warnings notes)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret))
                    (us-notelist-p (mv-nth 2 ret)))))
    :hints(("Goal" :in-theory (enable us-mark-wires-for-modinst)))))




(defsection us-mark-wires-for-modinstlist

  (defund us-mark-wires-for-modinstlist
    (x        ; the modinstlist to process
     walist   ; walist for the current module
     db       ; db for the current module (may be extended)
     mods     ; all modules
     modalist ; modalist for all modules
     dbalist ; dbalist-p that should bind every submodule (due to dependency order traversal)
     all-walists ; precomputed walists for all mods
     warnings    ; warnings accumulator (may be extended)
     notes       ; notes accumulator (may be extended)
     )
    "Returns (MV WARNINGS DB NOTES)"
    (declare (xargs :guard (and (vl-modinstlist-p x)
                                (vl-wirealist-p walist)
                                (us-db-p db)
                                (vl-modulelist-p mods)
                                (equal modalist (vl-modalist mods))
                                (us-dbalist-p dbalist)
                                (equal all-walists (vl-nowarn-all-wirealists mods))
                                (vl-warninglist-p warnings)
                                (us-notelist-p notes))))
    (b* (((when (atom x))
          (mv warnings db notes))
         ((mv warnings db notes)
          (us-mark-wires-for-modinst (car x) walist db mods modalist
                                     dbalist all-walists warnings notes))
         ((mv warnings db notes)
          (us-mark-wires-for-modinstlist (cdr x) walist db mods modalist
                                         dbalist all-walists warnings notes)))
      (mv warnings db notes)))

  (defthm us-mark-wires-for-modinstlist-basics
    (implies (and (force (vl-modinstlist-p x))
                  (force (vl-wirealist-p walist))
                  (force (us-db-p db))
                  (force (vl-modulelist-p mods))
                  (force (equal modalist (vl-modalist mods)))
                  (force (us-dbalist-p dbalist))
                  (force (equal all-walists (vl-nowarn-all-wirealists mods)))
                  (force (vl-warninglist-p warnings))
                  (force (us-notelist-p notes)))
             (let ((ret (us-mark-wires-for-modinstlist x walist db mods modalist dbalist all-walists
                                                       warnings notes)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret))
                    (us-notelist-p (mv-nth 2 ret)))))
    :hints(("Goal" :in-theory (enable us-mark-wires-for-modinstlist)))))





(defsection us-union-masks

  (defund us-union-masks (super wires db warnings)
    "Returns (MV WARNINGS MASK)"
    (declare (xargs :guard (and (stringp super)
                                (vl-emodwirelist-p wires)
                                (us-db-p db)
                                (vl-warninglist-p warnings))))
    (b* (((when (atom wires))
          (mv warnings 0))
         ((mv warnings cdr-mask)
          (us-union-masks super (cdr wires) db warnings))
         (entry1 (hons-get (car wires) db))
         ((unless entry1)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "In ~m0, expected use-set database entry for ~s1.  ~
                         Assuming unused/unset.  The used/set from above info ~
                         for ports may be incorrect."
                   :args (list super (car wires))
                   :fn 'us-union-masks
                   :fatalp nil)))
            (mv (cons w warnings) cdr-mask)))
         (mask (acl2::bitset-insert (cdr entry1) cdr-mask)))
      (mv warnings mask)))

  (defthm us-union-masks-basics
    (implies (and (force (stringp super))
                  (force (vl-emodwirelist-p wires))
                  (force (us-db-p db))
                  (force (vl-warninglist-p warnings)))
             (let ((ret (us-union-masks super wires db warnings)))
               (and (vl-warninglist-p (mv-nth 0 ret))
                    (natp (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-union-masks)))))


(defsection us-mark-wires-for-notes

  (defund us-mark-wires-for-notes (submod mask wires db reportcard)
    "Returns (MV REPORTCARD DB)"
    (declare (xargs :guard (and (stringp submod)
                                (natp mask)
                                (vl-emodwirelist-p wires)
                                (us-db-p db)
                                (vl-reportcard-p reportcard))))
    (b* (((when (atom wires))
          (mv reportcard db))
         ((mv reportcard db)
          (us-mark-wires-for-notes submod mask (cdr wires) db reportcard))
         (wire1-look (hons-get (car wires) db))
         ((unless wire1-look)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "Expected use-set database entry for ~s0.  Ignoring this wire."
                   :args (list (car wires))
                   :fn 'us-mark-wires-for-notes
                   :fatalp nil)))
            (mv (vl-extend-reportcard submod w reportcard) db)))
         (curr-mask (cdr wire1-look))
         (new-mask  (acl2::bitset-union curr-mask mask))
         ((when (= curr-mask new-mask))
          ;; nothing to do
          (mv reportcard db))
         (db (hons-acons (car wires) new-mask db)))
      (mv reportcard db)))

  (defthm us-mark-wires-for-notes-basics
    (implies (and (force (stringp submod))
                  (force (natp mask))
                  (force (vl-emodwirelist-p wires))
                  (force (us-db-p db))
                  (force (vl-reportcard-p reportcard)))
             (let ((ret (us-mark-wires-for-notes submod mask wires db reportcard)))
               (and (vl-reportcard-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-mark-wires-for-notes)))))


(defsection us-apply-notes

  (defund us-apply-notes (super notes db dbalist reportcard)
    "Returns (MV REPORTCARD' DBALIST')"
    (declare (xargs :guard (and (stringp super)
                                (us-notelist-p notes)
                                (us-db-p db)           ; DB for the current module
                                (us-dbalist-p dbalist) ; DBS for the submodules
                                (vl-reportcard-p reportcard))
                    :verify-guards nil))
    (b* (((when (atom notes))
          (mv reportcard dbalist))

         ((mv reportcard dbalist)
          (us-apply-notes super (cdr notes) db dbalist reportcard))

         ((us-note note1) (car notes))

         (sub-db-look (hons-get note1.submod dbalist))
         (sub-db      (cdr sub-db-look))
         ((unless sub-db-look)
          (b* ((w (make-vl-warning
                   :type :use-set-fudging
                   :msg "Expected an entry for ~m0 in the dbalist.  Failing to record ~
                       superior uses/sets of ~&1."
                   :args (list note1.submod note1.formals)
                   :fatalp nil
                   :fn 'us-apply-notes)))
            (mv (vl-extend-reportcard note1.submod w reportcard)
                dbalist)))

         ((mv warnings actuals-mask)
          (us-union-masks super note1.actuals db nil))

         (reportcard (if (consp warnings)
                      (vl-extend-reportcard-list note1.submod warnings reportcard)
                    reportcard))

         (above-mask 0)
         ;; a wire is used above the submodule if used in the current module or
         ;; used above the current module.
         (above-mask (if (or (acl2::bitset-memberp *us-truly-setp* actuals-mask)
                             (acl2::bitset-memberp *us-truly-set-abovep* actuals-mask))
                         (acl2::bitset-insert *us-truly-set-abovep* above-mask)
                       above-mask))
         (above-mask (if (or (acl2::bitset-memberp *us-truly-usedp* actuals-mask)
                             (acl2::bitset-memberp *us-truly-used-abovep* actuals-mask))
                         (acl2::bitset-insert *us-truly-used-abovep* above-mask)
                       above-mask))

         ((mv reportcard new-sub-db) (us-mark-wires-for-notes note1.submod above-mask note1.formals sub-db reportcard))
         (dbalist                 (hons-acons note1.submod new-sub-db dbalist))

         )
      (mv reportcard dbalist)))

  (defthm us-apply-notes-basics
    (implies (and (force (stringp super))
                  (force (us-notelist-p notes))
                  (force (us-db-p db))
                  (force (us-dbalist-p dbalist))
                  (force (vl-reportcard-p reportcard)))
             (let ((ret (us-apply-notes super notes db dbalist reportcard)))
               (and (vl-reportcard-p (mv-nth 0 ret))
                    (us-dbalist-p (mv-nth 1 ret))
                    )))
    :hints(("Goal"
            :do-not '(generalize fertilize eliminate-destructors)
            :in-theory (enable us-apply-notes))))

  (verify-guards us-apply-notes))



(defsection us-apply-notesalist

  (defund us-apply-notesalist (x notealist dbalist reportcard)
    "Returns (MV REPORTCARD' DBALIST')"
    (declare (xargs :guard (and (vl-modulelist-p x)
                                (us-notealist-p notealist)
                                (us-dbalist-p dbalist)
                                (vl-reportcard-p reportcard))))
    (b* (((when (atom x))
          (mv reportcard dbalist))

         ((vl-module x1) (car x))
         (db-look    (hons-get x1.name dbalist))
         (notes-look (hons-get x1.name notealist))
         (db         (cdr db-look))
         (notes      (cdr notes-look))
         (reportcard
          (if (and db-look notes-look)
              reportcard
            (b* ((w (make-vl-warning
                     :type :use-set-fudging
                     :msg "Expected use-set database and notes for ~
                                 module ~m0.  Not propagating used/set from ~
                                 above information."
                     :args (list x1.name)
                     :fatalp nil
                     :fn 'us-apply-notesalist)))
              (vl-extend-reportcard x1.name w reportcard))))
         ((mv reportcard dbalist)
          (us-apply-notes x1.name notes db dbalist reportcard))
         ((mv reportcard dbalist)
          (us-apply-notesalist (cdr x) notealist dbalist reportcard)))
      (mv reportcard dbalist)))

  (defthm us-apply-notesalist-basics
    (implies (and (force (vl-modulelist-p x))
                  (force (us-notealist-p notealist))
                  (force (us-dbalist-p dbalist))
                  (force (vl-reportcard-p reportcard)))
             (let ((ret (us-apply-notesalist x notealist dbalist reportcard)))
               (and (vl-reportcard-p (mv-nth 0 ret))
                    (us-dbalist-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-apply-notesalist)))))



(defalist us-results-p (x)
  :key (natp x)
  :val (vl-emodwirelist-p x)
  :keyp-of-nil nil
  :valp-of-nil t)


(defsection us-organize-results

; Invert the database so that each bit-set is associated with the list of wires
; that have it.  This way you can extract the wires that have any particular
; property you want, e.g., "never used and never set", by just looking at the
; wires for the appropriate bitset.

; ASSUMES THE DATABSE HAS ALREADY BEEN SHRUNK.

  (defund us-organize-results-aux (db buckets)
    ;; DB binds names to masks.  Buckets binds masks to names.
    (declare (xargs :guard (us-db-p db)))
    (b* (((when (atom db))
          buckets)
         (name1      (caar db))
         (val1       (cdar db))
         (val1-wires (cdr (hons-get val1 buckets)))
         (buckets    (hons-acons val1 (cons name1 val1-wires) buckets)))
      (us-organize-results-aux (cdr db) buckets)))

  (defthm us-results-p-of-us-organize-results-aux
    (implies (and (force (us-db-p db))
                  (force (us-results-p buckets)))
             (us-results-p (us-organize-results-aux db buckets)))
    :hints(("Goal"
            :do-not '(generalize fertilize)
            :in-theory (e/d (us-organize-results-aux)
                            (hons-acons)))))

  (defund us-organize-results (db)
    (declare (xargs :guard (us-db-p db)))
    (b* ((temp (us-organize-results-aux db nil))
         (ret  (hons-shrink-alist temp nil))
         (-    (fast-alist-free temp))
         (-    (fast-alist-free ret)))
      ret))

  (defthm us-results-p-of-us-organize-results
    (implies (force (us-db-p db))
             (us-results-p (us-organize-results db)))
    :hints(("Goal" :in-theory (enable us-organize-results)))))


(defsection us-filter-db-by-names

;; Get entries that have particular names

; ASSUMES THE DATABSE HAS ALREADY BEEN SHRUNK

  (defund us-filter-db-by-names1 (names names-fal db yes no)
    "Returns (MV YES NO), slow alists."
    (declare (xargs :guard (and (equal names-fal (make-lookup-alist names))
                                (us-db-p db))))
    (b* (((when (atom db))
          (mv yes no))
         ((mv yes no)
          (if (fast-memberp (caar db) names names-fal)
              (mv (cons (car db) yes) no)
            (mv yes (cons (car db) no)))))
      (us-filter-db-by-names1 names names-fal (cdr db) yes no)))

  (defund us-filter-db-by-names (names db)
    "Returns (MV YES NO), slow alists."
    (declare (xargs :guard (us-db-p db)))
    (b* ((fal (make-lookup-alist names))
         ((mv yes no) (us-filter-db-by-names1 names fal db nil nil))
         (- (fast-alist-free fal)))
      (mv yes no)))

  (defthm us-filter-db-by-names1-basics
    (implies (and (force (equal names-fal (make-lookup-alist names)))
                  (force (us-db-p db))
                  (force (us-db-p yes))
                  (force (us-db-p no)))
             (let ((ret (us-filter-db-by-names1 names names-fal db yes no)))
               (and (us-db-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-filter-db-by-names1))))

  (defthm us-filter-db-by-names-basics
    (implies (force (us-db-p db))
             (let ((ret (us-filter-db-by-names names db)))
               (and (us-db-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-filter-db-by-names)))))


(defsection us-filter-db-by-bit

  ;; Get entries that have a particular bit set

; ASSUMES THE DATABSE HAS ALREADY BEEN SHRUNK

  (defund us-filter-db-by-bit1 (bit db yes no)
    "Returns (MV YES NO), slow alists."
    (declare (xargs :guard (and (natp bit)
                                (us-db-p db))))
    (b* (((when (atom db))
          (mv yes no))
         ((mv yes no)
          (if (acl2::bitset-memberp bit (cdar db))
              (mv (cons (car db) yes) no)
            (mv yes (cons (car db) no)))))
      (us-filter-db-by-bit1 bit (cdr db) yes no)))

  (defund us-filter-db-by-bit (bit db)
    "Returns (MV YES NO), slow alists."
    (declare (xargs :guard (and (natp bit)
                                (us-db-p db))))
    (us-filter-db-by-bit1 bit db nil nil))

  (defthm us-filter-db-by-bit1-basics
    (implies (and (force (natp bit))
                  (force (us-db-p db))
                  (force (us-db-p yes))
                  (force (us-db-p no)))
             (let ((ret (us-filter-db-by-bit1 bit db yes no)))
               (and (us-db-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-filter-db-by-bit1))))

  (defthm us-filter-db-by-bit-basics
    (implies (and (force (natp bit))
                  (force (us-db-p db)))
             (let ((ret (us-filter-db-by-bit bit db)))
               (and (us-db-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-filter-db-by-bit)))))


(defsection us-filter-db-by-mask

  ;; Get entries that have exactly some mask

; ASSUMES THE DATABSE HAS ALREADY BEEN SHRUNK

  (defund us-filter-db-by-mask1 (mask db yes no)
    "Returns (MV YES NO), slow alists."
    (declare (xargs :guard (and (natp mask)
                                (us-db-p db))))
    (b* (((when (atom db))
          (mv yes no))
         ((mv yes no)
          (if (equal mask (cdar db))
              (mv (cons (car db) yes) no)
            (mv yes (cons (car db) no)))))
      (us-filter-db-by-mask1 mask (cdr db) yes no)))

  (defund us-filter-db-by-mask (mask db)
    "Returns (MV YES NO), slow alists."
    (declare (xargs :guard (and (natp mask)
                                (us-db-p db))))
    (us-filter-db-by-mask1 mask db nil nil))

  (defthm us-filter-db-by-mask1-basics
    (implies (and (force (natp mask))
                  (force (us-db-p db))
                  (force (us-db-p yes))
                  (force (us-db-p no)))
             (let ((ret (us-filter-db-by-mask1 mask db yes no)))
               (and (us-db-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-filter-db-by-mask1))))

  (defthm us-filter-db-by-mask-basics
    (implies (and (force (natp mask))
                  (force (us-db-p db)))
             (let ((ret (us-filter-db-by-mask mask db)))
               (and (us-db-p (mv-nth 0 ret))
                    (us-db-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-filter-db-by-mask)))))


(defsection us-warn-nonport-results

  (defund us-warn-nonport-results (modname x)
    (declare (xargs :guard (and (stringp modname)
                                (us-results-p x))))
    (b* (((when (atom x))
          nil)
         (mask  (caar x))
         (wires (cdar x))
         ((when (atom wires))
          (us-warn-nonport-results modname (cdr x)))

         (- (or (not (or (acl2::bitset-memberp *us-truly-used-abovep* mask)
                         (acl2::bitset-memberp *us-truly-set-abovep* mask)))
                (cw "Errr... non-ports marked used/set above??? something is wrong.~%")))

         ;; used/set?
         (usedp (acl2::bitset-memberp *us-truly-usedp* mask))
         (setp  (acl2::bitset-memberp *us-truly-setp* mask))
         ((when (and usedp setp))
          ;; It's fine, no reason to warn about it.  We've already warned
          ;; about trainwrecks earlier.
          (us-warn-nonport-results modname (cdr x)))

         ;; falsely used/set but not truly used/set?
         (fusedp (and (not usedp) (acl2::bitset-memberp *us-falsely-usedp* mask)))
         (fsetp  (and (not setp)  (acl2::bitset-memberp *us-falsely-setp* mask)))

         (pluralp     (vl-plural-p wires))
         (|wire(s)|   (if pluralp "wires" "wire"))
         (|are|       (if pluralp "are" "is"))

         (summary-line
          ;; New summary line for Terry
          (cat (natstr (len wires))
               (cond (usedp " unset bit")
                     (setp  " unused bit")
                     (t     " spurious bit"))
               (if pluralp "s.  " ".  ")))

         (warning
          (make-vl-warning
           :type (cond (usedp (if fsetp
                                  :use-set-warn-1-unset-tricky
                                :use-set-warn-1-unset))
                       (setp  (if fusedp
                                  :use-set-warn-2-unused-tricky
                                :use-set-warn-2-unused))
                       (t     (if (or fusedp fsetp)
                                  :use-set-warn-3-spurious-tricky
                                :use-set-warn-3-spurious)))
           :msg (cat summary-line
                     (cond (usedp "These ~s0 ~s1 never set: ~&2.")
                           (setp  "These ~s0 ~s1 never used: ~&2.")
                           (t     "These ~s0 ~s1 never used or set: ~&2.")))
           :args (list |wire(s)|
                       |are|
                       (cwtime (vl-verilogify-emodwirelist wires)
                               :mintime 1/2))
           :fatalp nil
           :fn 'us-warn-nonport-results)))

      (cons warning
            (us-warn-nonport-results modname (cdr x)))))

  (defthm vl-warninglist-p-of-us-warn-nonport-results
    (vl-warninglist-p (us-warn-nonport-results modname x))
    :hints(("Goal" :in-theory (enable us-warn-nonport-results)))))

(define vl-vardecls-for-flattened-hids ((x vl-vardecllist-p))
  :returns (flattened-decls vl-vardecllist-p :hyp :fguard)
  (cond ((atom x)
         nil)
        ((assoc-equal "VL_HID_RESOLVED_MODULE_NAME" (vl-vardecl->atts (car x)))
         (cons (car x) (vl-vardecls-for-flattened-hids (cdr x))))
        (t
         (vl-vardecls-for-flattened-hids (cdr x)))))

(define vl-vardecllist-wires
  ((x        vl-vardecllist-p)
   (walist   vl-wirealist-p)
   (warnings vl-warninglist-p))
  :returns (mv (successp booleanp :rule-classes :type-prescription)
               (warnings vl-warninglist-p)
               (wires    vl-emodwirelist-p :hyp :fguard))
  (b* (((when (atom x))
        (mv t (ok) nil))
       ((vl-vardecl x1) (car x))
       (car-look     (hons-get x1.name walist))
       (car-wires    (cdr car-look))
       (warnings     (if car-look
                         (ok)
                       (warn :type :use-set-fudging
                             :msg "~a0: No wires for this variable?"
                             :args (list (car x)))))
       ((mv cdr-successp warnings cdr-wires)
        (vl-vardecllist-wires (cdr x) walist warnings)))
    (mv (and car-look cdr-successp)
        warnings
        (append car-wires cdr-wires))))

(define us-report-mod ((x       vl-module-p)
                       (dbalist us-dbalist-p)
                       (walist  vl-wirealist-p))
  :returns (new-x vl-module-p :hyp :fguard)
  (b* (((vl-module x) x)
       (warnings x.warnings)

       (entry (hons-get x.name dbalist))
       (db    (cdr entry))
       ((unless entry)
        (b* ((warnings (warn :type :use-set-fudging
                             :msg "Expected a use-set database for ~m0; no ~
                                   use-set information will be available for ~
                                   this module."
                             :args (list x.name))))
          (change-vl-module x :warnings warnings)))

       ;; Crucial: shrink the database to remove shadowed elements
       (db (hons-shrink-alist db nil))

       (ialist (vl-moditem-alist x))
       ((mv warnings ignore-bits)
        (us-analyze-commentmap x.comments x ialist walist warnings))
       (- (fast-alist-free ialist))

       ((mv ?ignore-db1 db)
        (us-filter-db-by-names
         (append
          #!ACL2 '( ;; always ignore vbna, vbpa, vss0, vdd0 since they're common and stupid
                   |vbna| |vbpa| |vss0| |vdd0|
                   ;; also ignore certain clocks...
                   |d1ph1| |d2ph1| |d3ph1| |e1ph1| |e2ph1| |e3ph1|
                   )
          ;; bits to ignore from use_set_ignore(...); directives
          ignore-bits)
         db))

       ;; ignore hids since they'll look undriven
       (hids (vl-vardecls-for-flattened-hids x.vardecls))
       ((mv ?hidnames-okp warnings hidwires)
        (vl-vardecllist-wires hids walist warnings))
       ((mv ?ignore-db2 db)
        (us-filter-db-by-names hidwires db))

       ((mv successp warnings1 port-wires) (us-portdecllist-bits x.portdecls walist))
       (warnings                           (append-without-guard warnings1 warnings))
       ((unless successp)
        (b* ((warnings (warn :type :use-set-fudging
                             :msg "Failed to generate all port wires for ~m0; ~
                                   no use-set information will be available ~
                                   for this module."
                             :args (list x.name))))
          (change-vl-module x :warnings warnings)))

       ;; We'll handle port and internal wires separately.
       ((mv ?extern-db intern-db)
        (us-filter-db-by-names port-wires db))

       (intern-results (us-organize-results intern-db))
       (warnings2      (us-warn-nonport-results x.name intern-results))
       (warnings       (append warnings2 warnings))

       (- (fast-alist-free db)))

    (change-vl-module x :warnings warnings)))


(define us-report-mods
  ((x           vl-modulelist-p)
   (mods        vl-modulelist-p)
   (dbalist     us-dbalist-p)
   (all-walists (equal all-walists (vl-nowarn-all-wirealists mods))))
  :returns (new-x vl-modulelist-p :hyp :fguard)
  (if (atom x)
      nil
    (cons (us-report-mod (car x)
                         dbalist
                         (cdr (hons-get (vl-module->name (car x)) all-walists)))
          (us-report-mods (cdr x) mods dbalist all-walists))))

(defsection us-analyze-mod

  (defund us-analyze-mod
    (x           ; module to analyze
     mods        ; list of all modules
     modalist    ; modalist for all modules
     dbalist     ; use-set databases for previously analyzed modules
     all-walists ; precomputed walists for all mods
     reportcard     ; reportcard we're building
     toplevel    ; list of top level modules
     notealist
     )
    "Returns (MV X' DBALIST' REPORTCARD' NOTEALIST')"
    (declare (xargs :guard (and (vl-module-p x)
                                (vl-modulelist-p mods)
                                (equal modalist (vl-modalist mods))
                                (us-dbalist-p dbalist)
                                (equal all-walists (vl-nowarn-all-wirealists mods))
                                (vl-reportcard-p reportcard)
                                (string-listp toplevel)
                                (us-notealist-p notealist))))
    (b* (((vl-module x) x)

         (walist-look (hons-get x.name all-walists))
         (walist      (cdr walist-look))
         ((unless walist-look)
          (er hard? 'us-analyze-mod "Expected a wire alist for ~x0." x.name)
          (mv x dbalist reportcard notealist))

;         (nwires (- (sum-lens walist) (len walist)))
;         (- (cw "Analyzing ~s0 (~x1 wires).~%" x.name nwires))

         ;; Separate for now.  Eventually use x.warnings.
         (warnings nil)
         (db (us-initialize-db walist))

         ((mv warnings db)
          ;; Special hack: mark top-level modules' as having their ports
          ;; used/set from above per their directions (inputs are "set",
          ;; outputs are "used", inputs are used and set.)
          (if (member-equal x.name toplevel)
              (us-mark-toplevel-port-bits x.portdecls walist db warnings)
            (mv warnings db)))

         ((mv warnings db) (cwtime (us-mark-wires-for-vardecllist x.vardecls walist db warnings)
                                   :mintime 1/2))
         ((mv warnings db) (cwtime (us-mark-wires-for-assignlist x.assigns walist db warnings)
                                   :mintime 1/2))
         ((mv warnings db) (cwtime (us-mark-wires-for-gateinstlist x.gateinsts walist db warnings)
                                   :mintime 1/2))
         ((mv warnings db) (cwtime (us-mark-wires-for-alwayslist x.alwayses walist db warnings)
                                   :mintime 1/2))
         ((mv warnings db) (cwtime (us-mark-wires-for-initiallist x.initials walist db warnings)
                                   :mintime 1/2))

         ((mv warnings db notes)
          (cwtime (us-mark-wires-for-modinstlist x.modinsts walist db mods modalist dbalist all-walists warnings nil)
                  :mintime 1/2))

         ;; bozo ugly db/walist order
         ((mv warnings db) (cwtime (us-mark-false-inouts x.portdecls db walist warnings)
                                   :mintime 1/2))

         (notealist (hons-acons x.name notes notealist))
         (dbalist (hons-acons x.name db dbalist))

;         (- (or (not warnings)
;                (vl-cw-ps-seq
;                 (vl-cw "~x0 warnings for ~s1.~%" (len warnings) x.name)
;                 (vl-print-warnings warnings))))

         (warnings (append-without-guard warnings x.warnings))
         (x-prime (change-vl-module x :warnings warnings)))

      (mv x-prime dbalist reportcard notealist)))

  (defthm us-analyze-mod-basics
    (implies (and (force (vl-module-p x))
                  (force (vl-modulelist-p mods))
                  (force (equal modalist (vl-modalist mods)))
                  (force (us-dbalist-p dbalist))
                  (force (equal all-walists (vl-nowarn-all-wirealists mods)))
                  (force (vl-reportcard-p reportcard))
                  (force (string-listp toplevel))
                  (force (us-notealist-p notealist)))
             (let ((ret (us-analyze-mod x mods modalist dbalist all-walists reportcard toplevel notealist)))
               (and (vl-module-p (mv-nth 0 ret))
                    (us-dbalist-p (mv-nth 1 ret))
                    (vl-reportcard-p (mv-nth 2 ret))
                    (us-notealist-p (mv-nth 3 ret)))))
    :hints(("Goal" :in-theory (enable us-analyze-mod)))))



(defsection us-analyze-mods

  (defund us-analyze-mods-aux (x mods modalist dbalist all-walists reportcard toplevel notealist)
    "Returns (MV X' DBALIST' REPORTCARD')"
    (declare (xargs :guard (and (vl-modulelist-p x)
                                (vl-modulelist-p mods)
                                (equal modalist (vl-modalist mods))
                                (us-dbalist-p dbalist)
                                (equal all-walists (vl-nowarn-all-wirealists mods))
                                (vl-reportcard-p reportcard)
                                (string-listp toplevel)
                                (us-notealist-p notealist))))
    (b* (((when (atom x))
          (mv nil dbalist reportcard notealist))
         ((mv car-prime dbalist reportcard notealist)
          (us-analyze-mod (car x) mods modalist dbalist
                          all-walists reportcard toplevel notealist))
         ((mv cdr-prime dbalist reportcard notealist)
          (us-analyze-mods-aux (cdr x) mods modalist dbalist
                               all-walists reportcard toplevel notealist))
         (x-prime (cons car-prime cdr-prime)))
      (mv x-prime dbalist reportcard notealist)))

  (defthm us-analyze-mods-aux-basics
    (implies (and (force (vl-modulelist-p x))
                  (force (vl-modulelist-p mods))
                  (force (equal modalist (vl-modalist mods)))
                  (force (us-dbalist-p dbalist))
                  (force (equal all-walists (vl-nowarn-all-wirealists mods)))
                  (force (vl-reportcard-p reportcard))
                  (force (string-listp toplevel))
                  (force (us-notealist-p notealist)))
             (let ((ret (us-analyze-mods-aux x mods modalist dbalist all-walists reportcard toplevel notealist)))
               (and (vl-modulelist-p (mv-nth 0 ret))
                    (us-dbalist-p (mv-nth 1 ret))
                    (vl-reportcard-p (mv-nth 2 ret))
                    (us-notealist-p (mv-nth 3 ret)))))
    :hints(("Goal" :in-theory (enable us-analyze-mods-aux))))

  (defund us-analyze-mods (x)
    "Returns (MV X-PRIME DBALIST)"
    (declare (xargs :guard (vl-modulelist-p x)
                    :guard-debug t))
    ;; bozo check port bits
    (b* ((x        (cwtime (vl-deporder-sort x) :mintime 1/2))
         (modalist (cwtime (vl-modalist x) :mintime 1/2))
         (toplevel (cwtime (vl-modulelist-toplevel x) :mintime 1/2))
         ((mv warnings-alist all-walists)
          (cwtime (vl-modulelist-all-wirealists x)
                  :mintime 1/2))

         ((mv x-prime dbalist warnings-alist notealist)
          ;; pass 1: analyze the modules in dependency order, bottom-up,
          ;; generating their initial dbalists and notes.
          (cwtime (us-analyze-mods-aux x x modalist (len x)
                                       all-walists warnings-alist
                                       toplevel (len x))
                  :mintime 1/2))
         (- (fast-alist-free modalist))

         ((mv warnings-alist dbalist)
          ;; pass2: apply the notes in reverse dependency order, top-down,
          ;; marking which ports are used/set anywhere above
          (cwtime (us-apply-notesalist (rev x-prime) notealist dbalist
                                       warnings-alist)
                  :mintime 1/2))
         (- (fast-alist-free notealist))

         (x-prime
          (cwtime (vl-modulelist-apply-reportcard x-prime warnings-alist)
                  :mintime 1/2))
         (- (fast-alist-free warnings-alist))

         (x-prime
          (cwtime (us-report-mods x-prime x dbalist all-walists)
                  :mintime 1/2))

         (- (fast-alist-free-each-alist-val all-walists))
         (- (fast-alist-free all-walists)))

      ;; bozo probably free other stuff -- walists, etc.
      (mv x-prime dbalist)))

  (defthm us-analyze-mods-basics
    (implies (force (vl-modulelist-p x))
             (let ((ret (us-analyze-mods x)))
               (and (vl-modulelist-p (mv-nth 0 ret))
                    (us-dbalist-p (mv-nth 1 ret)))))
    :hints(("Goal" :in-theory (enable us-analyze-mods)))))

(define vl-design-bit-use-set ((x vl-design-p))
  :returns (mv (new-x   vl-design-p)
               (dbalist us-dbalist-p))
  (b* ((x (vl-design-fix x))
       ((vl-design x) x)
       ((mv new-mods dbalist) (us-analyze-mods x.mods))
       (new-x (change-vl-design x :mods new-mods)))
    (mv new-x dbalist)))





