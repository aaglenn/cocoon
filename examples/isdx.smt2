(declare-datatypes () ((NetMask (mk-NetMask (nm-mask Int) (nm-len Int)))))
(declare-datatypes () ((ASMasks (mk-ASMasks (asm-as Int) (asm-masks (List NetMask))))))


(declare-var aslist  (List Int))
(declare-var aslist2 (List Int))
(declare-var nmlist  (List NetMask))
(declare-var nmlist2 (List NetMask))
(declare-var nm  NetMask)
(declare-var nm2 NetMask)
(declare-var as  Int)
(declare-var as2 Int)
(declare-var ip  Int)
(declare-var bgpdb  (List ASMasks))
(declare-var bgpdb2 (List ASMasks))
(declare-var asmasks  ASMasks)
(declare-var asmasks2 ASMasks)
(declare-var boolres  Bool)

(declare-rel elemASList (Int (List Int)))
(rule (=> (= aslist (insert as aslist2)) (elemASList as aslist)))
(rule (=> (and (= aslist (insert as2 aslist2)) (elemASList as aslist2)) (elemASList as aslist)))

(define-fun prefix_match ((ip Int) (nm NetMask)) Bool
 (= ip (nm-mask nm))
)

(declare-rel prefix_match_many (Int (List NetMask) Bool))
(rule (=> (= nmlist (as nil (List NetMask))) 
          (prefix_match_many ip nmlist false)))
(rule (=> (and (= nmlist (insert nm nmlist2)) 
               (prefix_match ip nm)) 
          (prefix_match_many ip nmlist true)))
(rule (=> (and (= nmlist (insert nm nmlist2)) 
               (not (prefix_match ip nm)) 
               (prefix_match_many ip nmlist2 boolres)) 
          (prefix_match_many ip nmlist boolres)))

(declare-rel check_bgp_match (Int Int (List ASMasks) Bool))
(rule (=> (= bgpdb (as nil (List ASMasks))) 
          (check_bgp_match ip as bgpdb false)))
(rule (=> (and (= bgpdb (insert asmasks bgpdb2)) 
               (not (= as (asm-as asmasks))) 
               (check_bgp_match ip as bgpdb2 boolres)) 
          (check_bgp_match ip as bgpdb boolres) ))
(rule (=> (and (= bgpdb (insert asmasks bgpdb2)) 
               (= as (asm-as asmasks)) 
               (prefix_match_many ip (asm-masks asmasks) true)) 
          (check_bgp_match ip as bgpdb true)))
(rule (=> (and (= bgpdb (insert asmasks bgpdb2)) 
               (= as (asm-as asmasks)) 
               (prefix_match_many ip (asm-masks asmasks) false) 
               (check_bgp_match ip as bgpdb2 boolres)) 
          (check_bgp_match ip as bgpdb boolres)))

(declare-rel bgp_match (Int (List ASMasks) (List Int)))
(rule (=> (and (= bgpdb (insert asmasks bgpdb2)) 
               (prefix_match_many ip (asm-masks asmasks) true) 
               (bgp_match ip bgpdb2 aslist)) 
          (bgp_match ip bgpdb (insert (asm-as asmasks) aslist))))
(rule (=> (and (= bgpdb (insert asmasks bgpdb2)) 
               (prefix_match_many ip (asm-masks asmasks) false) 
               (bgp_match ip bgpdb2 aslist)) 
          (bgp_match ip bgpdb aslist)))
(rule (=> (= bgpdb (as nil (List ASMasks)))
          (bgp_match ip bgpdb (as nil (List Int)))))

(declare-rel bug ((List ASMasks) Int Int))
(rule (=> (and (bgp_match ip bgpdb aslist) 
               (elemASList as aslist) 
               (check_bgp_match ip as bgpdb false)) 
          (bug bgpdb ip as)))

(query bug :print-certificate true)
