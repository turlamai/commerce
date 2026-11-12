147
((3) 0 () 1 ((q lib "commerce/main.rkt")) () (h ! (equal) ((c def c (c (? . 0) q offer)) q (125 . 11)) ((c def c (c (? . 0) q money)) q (0 . 4))))
procedure
(money currency minor-units) -> money?
  currency : string?
  minor-units : exact-nonnegative-integer?
procedure
(offer id                         
       product-id                 
       kind                       
       price                      
       entitlement-policy-id) -> offer?
  id : string?
  product-id : string?
  kind : (or/c 'one-time 'subscription)
  price : money?
  entitlement-policy-id : string?
