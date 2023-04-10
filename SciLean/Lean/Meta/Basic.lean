import Lean
import Std.Lean.Expr

import SciLean.Lean.Array

namespace Lean.Meta

variable {m} [Monad m] [MonadEnv m] [MonadError m]

def _root_.Lean.Expr.explicitArgIds (e : Expr) : Array Nat := 
  run e #[] 0
where run (e : Expr) (ids : Array Nat) (i : Nat) : Array Nat := 
  match e with
  | .forallE _ _ e' bi => 
    if bi.isExplicit then 
      run e' (ids.push i) (i+1)
    else 
      run e' ids (i+1)
  | .lam _ _ e' bi => 
    if bi.isExplicit then 
      run e' (ids.push i) (i+1)
    else 
      run e' ids (i+1)
  | _ => ids


partial def _root_.Lean.Expr.flattenLet (e : Expr) : Expr := 
  match e with
  | .letE xName xType xVal xBody _ => 
    match xVal with
    | .letE yName yType yVal yBody _ =>

      flattenLet $
        .letE yName yType yVal
          (.letE xName xType yBody (xBody.liftLooseBVars 1 1) default) default

    | _ => .letE xName xType xVal xBody default
  | _ => e


partial def _root_.Lean.Expr.flattenLet? (e : Expr) : Option Expr := do
  match e with
  | .letE xName xType xVal xBody _ => 
    match xVal with
    | .letE yName yType yVal yBody _ =>

      let e' := 
        .letE yName yType yVal
          (.letE xName xType yBody (xBody.liftLooseBVars 1 1) default) default

      return (flattenLet? e').getD e'

    | _ => do
      return (.letE xName xType xVal (← flattenLet? xBody) default)
  | _ => none


def getConstExplicitArgIds (constName : Name) : m (Array Nat) := do
  let info ← getConstInfo constName
  return info.type.explicitArgIds

def getConstArity (constName : Name) : m Nat := do
  let info ← getConstInfo constName
  return info.type.forallArity

/-- Changes structure projection back to function application. Left unchanged if not a projection.

For example `proj ``Prod 0 xy` is changed to `mkApp ``Prod.fst #[xy]`.
-/
def revertStructureProj (e : Expr) : MetaM Expr :=
  match e with
  | .proj name i struct => do
    let some info := getStructureInfo? (← getEnv) name
      | panic! "structure expected"
    let some projFn := info.getProjFn? i
      | panic! "valid projection index expected"
    mkAppM projFn #[struct]
  | _ => return e

/-- Is `e` in the form `foo x₀ .. xₙ` where `foo` is some constant

  It returns only explicit arguments and the original expression should be recoverable by `mkAppM foo #[x₀, .., xₙ]`
  -/
def getExplicitArgs (e : Expr) : MetaM (Option (Name×Array Expr)) := do
  let .some (funName, _) := e.getAppFn.const?
    | return none
  
  let n ← getConstArity funName
  let explicitArgIds ← getConstExplicitArgIds funName

  let args := e.getAppArgs

  let explicitArgs := explicitArgIds.foldl (init := #[])
    λ a id => if h : id < args.size then a.push args[id] else a
  
  return (funName, explicitArgs)



/--
  Same as `mkAppM` but does not leave trailing implicit arguments.

  For example for `foo : (X : Type) → [OfNat 0 X] → X` the ``mkAppNoTrailingM `foo #[X]`` produces `foo X : X` instead of `@foo X : [OfNat 0 X] → X`
-/
def mkAppNoTrailingM (constName : Name) (xs : Array Expr) : MetaM Expr := do

  let n ← getConstArity constName
  let explicitArgIds ← getConstExplicitArgIds constName

  -- number of arguments to apply
  let argCount := explicitArgIds[xs.size]? |>.getD n

  let mut args : Array (Option Expr) := Array.mkArray argCount none
  for i in [0:xs.size] do
    args := args.set! explicitArgIds[i]! (.some xs[i]!)

  mkAppOptM constName args

def mkAppFoldrM (const : Name) (xs : Array Expr) : MetaM Expr := do
  if xs.size = 0 then
    return default
  if xs.size = 1 then
    return xs[0]!
  else
    xs.joinrM pure
      λ x p =>
        mkAppM const #[x,p]

def mkAppFoldlM (const : Name) (xs : Array Expr) : MetaM Expr := do
  if xs.size = 0 then
    return default
  if xs.size = 1 then
    return xs[0]!
  else
    xs.joinlM pure
      λ p x =>
        mkAppM const #[p,x]

/--
For `#[x₁, .., xₙ]` create `(x₁, .., xₙ)`.
-/
def mkProdElem (xs : Array Expr) : MetaM Expr := mkAppFoldrM ``Prod.mk xs

def mkProdFst (x : Expr) : MetaM Expr := mkAppM ``Prod.fst #[x]
def mkProdSnd (x : Expr) : MetaM Expr := mkAppM ``Prod.snd #[x]

/--
For `(x₀, .., xₙ₋₁)` return `xᵢ` but as a product projection.

We need to know the total size of the product to be considered.

For example for `xyz : X × Y × Z`
  - `mkProdProj xyz 1 3` returns `xyz.snd.fst`.
  - `mkProdProj xyz 1 2` returns `xyz.snd`.
-/
def mkProdProj (x : Expr) (i : Nat) (n : Nat) : MetaM Expr := do
  let X ← inferType x
  if X.isAppOfArity ``Prod 2 then
     match i, n with
     | _, 0 => pure x
     | _, 1 => pure x
     | 0, _ => mkAppM ``Prod.fst #[x]
     | i'+1, n'+1 => mkProdProj (← mkAppM ``Prod.snd #[x]) i' n'
  else
    if i = 0 then
      return x
    else
      throwError "Failed `mkProdProj`, can't take {i}-th element of {← ppExpr x}. It has type {← ppExpr X} which is not a product type!"


def mkProdSplitElem (xs : Expr) (n : Nat) : MetaM (Array Expr) := 
  (Array.mkArray n 0)
    |>.mapIdx (λ i _ => i.1)
    |>.mapM (λ i => mkProdProj xs i n)

def mkUncurryFun (n : Nat) (f : Expr) : MetaM Expr := do
  if n ≤ 1 then
    return f
  forallTelescope (← inferType f) λ xs _ => do
    let xs := xs[0:n]

    let xProdName : String ← xs.foldlM (init:="") λ n x => 
      do return (n ++ toString (← x.fvarId!.getUserName))
    let xProdType ← inferType (← mkProdElem xs)

    withLocalDecl xProdName default xProdType λ xProd => do
      let xs' ← mkProdSplitElem xProd n
      mkLambdaFVars #[xProd] (← mkAppM' f xs').headBeta


@[inline] def map3MetaM [MonadControlT MetaM m] [Monad m]
  (f : forall {α}, (β → γ → δ → MetaM α) → MetaM α) 
  {α} (k : β → γ → δ → m α) : m α :=
  controlAt MetaM fun runInBase => f (fun b c d => runInBase <| k b c d)

@[inline] def map4MetaM [MonadControlT MetaM m] [Monad m] 
  (f : forall {α}, (β → γ → δ → ε → MetaM α) → MetaM α) 
  {α} (k : β → γ → δ → ε → m α) : m α :=
  controlAt MetaM fun runInBase => f (fun b c d e => runInBase <| k b c d e)


private def letTelescopeImpl (e : Expr) (k : Array Expr → Expr → MetaM α) : MetaM α := 
  lambdaLetTelescope e λ xs b => do
    if let .some i ← xs.findIdxM? (λ x => do pure ¬(← x.fvarId!.isLetVar)) then
      k xs[0:i] (← mkLambdaFVars xs[i:] b)
    else
      k xs b

variable [MonadControlT MetaM n] [Monad n]

def letTelescope (e : Expr) (k : Array Expr → Expr → n α) : n α := 
  map2MetaM (fun k => letTelescopeImpl e k) k
