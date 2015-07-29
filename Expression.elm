module Expression
  ( Expression(..)
  , Environment
  , evaluate
  , evaluateExn
  , parse
  , derivative
  , optimize
  , toString
  , variables
  ) where

{-| A type for simple mathematical expressions.

# Types
@docs Expression, Environment

# Parsing
@docs parse

# Evaluation
@docs evaluate, evaluateExn

# Differentiation
@docs derivative
-}

import Dict
import Set
import Maybe
import Native.ParseExpression

-- TODO: Add sin, cos, tan, cosh, sinh, tanh

type Expression
  = Var String
  | Constant Float
  | Mul Expression Expression
  | Add Expression Expression
  | Exp Float Expression
  | Pow Expression Float
  | LogBase Float Expression
  | Sin Expression
  | Cos Expression


{-| An environment of values for variables to be used in evaluating an expression. -}
type alias Environment = Dict.Dict String Float

{-| Parse an expression from a string. -}
parse : String -> Result String Expression
parse = Native.ParseExpression.parse

toString : Expression -> String
toString =
  let parenthesize x = "(" ++ x ++ ")"
  in \expr ->
  case expr of
    Var x ->
      x
    Constant x ->
      Basics.toString x
    Add e1 e2 ->
      parenthesize (toString e1 ++ " + " ++ toString e2)
    Mul e1 e2 ->
      parenthesize (toString e1 ++ " * " ++ toString e2)
    Exp b e1 ->
      parenthesize ((if b < 0 then parenthesize else identity) (Basics.toString b) ++ "^" ++ toString e1)
    Pow e1 p ->
      parenthesize (toString e1 ++ "^" ++ Basics.toString p)
    LogBase b e1 ->
      if b == e
      then "log(" ++ toString e1 ++ ")"
      else "log(" ++ Basics.toString b ++ "," ++ toString e1 ++ ")"
    Sin e1 ->
      "sin(" ++ toString e1 ++ ")"
    Cos e1 ->
      "cos(" ++ toString e1 ++ ")"

maybeMap2 : (a -> b -> c) -> Maybe a -> Maybe b -> Maybe c
maybeMap2 f ma mb =
  case ma of
    Just a ->
      case mb of
        Just b -> Just (f a b)
        Nothing -> Nothing
    Nothing -> Nothing

{-| Evaluate an expression in the given environment, returning `Nothing` if a variable is not found. -}
evaluate : Expression -> (Environment -> Maybe Float)
evaluate expr env =
  case expr of
    Var x ->
      Dict.get x env

    Constant c ->
      Just c

    Mul e1 e2 ->
      maybeMap2 (*) (evaluate e1 env) (evaluate e2 env)

    Add e1 e2 ->
      maybeMap2 (+) (evaluate e1 env) (evaluate e2 env)

    LogBase b e1 ->
      Maybe.map (logBase b) (evaluate e1 env)

    Exp b e1 ->
      Maybe.map (\x -> b ^ x) (evaluate e1 env)

    Pow e1 p ->
      Maybe.map (\x -> x ^ p) (evaluate e1 env)

    Sin e1 ->
      Maybe.map sin (evaluate e1 env)

    Cos e1 ->
      Maybe.map cos (evaluate e1 env)

{-| Evaluate an expression in the given environment, throwing an exception if a variable is not found. -}
evaluateExn : Expression -> (Environment -> Float)
evaluateExn expr env =
  case expr of
    Var x ->
      case Dict.get x env of { Just a -> a }

    Constant c ->
      c

    Mul e1 e2 ->
      evaluateExn e1 env * evaluateExn e2 env

    Add e1 e2 ->
      evaluateExn e1 env + evaluateExn e2 env

    LogBase b e1 ->
      logBase b (evaluateExn e1 env)

    Exp b e1 ->
      b ^ (evaluateExn e1 env)

    Pow e1 p ->
      (evaluateExn e1 env) ^ p

    Sin e1 ->
      sin (evaluateExn e1 env)

    Cos e1 ->
      cos (evaluateExn e1 env)

{-| Take the derivative of an expression with respect to the given variable. -}
derivative : String -> Expression -> Expression
derivative x expr =
  case expr of
    Var y ->
      if y == x then Constant 1 else Constant 0

    Constant _ -> Constant 0

    Mul e1 e2 ->
      Add (Mul e1 (derivative x e2)) (Mul (derivative x e1) e2)

    Add e1 e2 ->
      Add (derivative x e1) (derivative x e2)

    LogBase b e1 ->
      let d = derivative x e1 in
      Mul d (Pow (Mul (Constant (logBase e b)) e1) (-1))

    Exp b e1 ->
      let d = derivative x e1 in
      Mul (Constant (logBase e b)) (Mul d expr)

    Pow e1 p ->
      Mul (derivative x e1)
        (Mul (Constant p) (Pow e1 (p - 1)))

    Sin e1 ->
      Mul (derivative x e1) (Cos e1)

    Cos e1 ->
      Mul (Constant (-1))
        (Mul (derivative x e1) (Sin e1))

-- TODO: Do a proper optimization at some point with putting things into a normal
-- form.
optimize : Expression -> Expression
optimize expr =
  case expr of
    Var _ ->
      expr

    Constant _ ->
      expr

    Mul e1 e2 ->
      case (optimize e1, optimize e2) of
        (Constant 0, _) ->
          Constant 0

        (_, Constant 0) ->
          Constant 0

        (Constant x, Constant y) ->
          Constant (x * y)

        (Constant 1, e2') ->
          e2'

        (e1', Constant 1) ->
          e1'

        (e1', e2') ->
          Mul e1' e2'

    Add e1 e2 ->
      case (optimize e1, optimize e2) of
        (Constant 0, e2') ->
          e2'

        (e1', Constant 0) ->
          e1'

        (Constant x, Constant y) ->
          Constant (x + y)

        (e1', e2') ->
          Add e1' e2'

    LogBase b e1 ->
      case optimize e1 of
        Constant x ->
          Constant (logBase b x)
        e1' ->
          LogBase b e1'

    Exp b e1 ->
      case optimize e1 of
        Constant x ->
          Constant (b ^ x)

        e1' ->
          Exp b e1'

    Pow e1 p ->
      case optimize e1 of
        Constant x ->
          Constant (x ^ p)

        e1' ->
          Pow e1' p

    Sin e1 ->
      case optimize e1 of
        Constant x ->
          Constant (sin x)

        e1' ->
          Sin e1'

    Cos e1 ->
      case optimize e1 of
        Constant x ->
          Constant (cos x)

        e1' ->
          Cos e1'

variables : Expression -> Set.Set String
variables =
  let
    go acc expr =
      case expr of
        Var x -> Set.insert x acc
        Constant _ -> acc
        Mul e1 e2 -> go (go acc e1) e2
        Add e1 e2 -> go (go acc e1) e2
        Exp _ e1 -> go acc e1
        Pow e1 _ -> go acc e1
        LogBase _ e1 -> go acc e1
        Sin e1 -> go acc e1
        Cos e1 -> go acc e1
  in
  go Set.empty


{-
envName : String
envName = "__elmexpressionenvironment"

compileToString : Expression -> String
compileToString =
  let parenthesize x = "(" ++ x ++ ")"
  \e ->
  case e of
    Var x ->
      "__elmexpressionenvironment" ++ "[" ++ toString x ++ "]"

    Constant x ->
      parenthesize (toString x)

    Mul e1 e2 ->
      parenthesize (compileToString e1 ++ "*" ++ compileToString e2)

    Add e1 e2 ->
      parenthesize (compileToString e1 ++ "+" ++ compileToString e2)

    LogBase b e1 ->
      parenthesize ("Math.log(" ++ compileToString e1 ++ ") / Math.log(" ++ toString b ++ ")")

    Exp b e1 ->
      "Math.pow(" ++ toString b ++ "," ++ compileToString e1 ++ ")"

    Pow e1 p ->
      "Math.pow(" ++ compileToString e1 ++ "," ++ toString p ++ ")"

-- Would be type:
-- Native.CompileExpression : String -> (Object -> Float)

compileExpressionString : String -> (Dict String Float -> Float)
compileExpressionString s =
-}
