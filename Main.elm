module Main where

import Expression exposing (Expression(..), derivative)
import ODE
import Dict
import Array
import Graphics.Collage exposing (..)
import Graphics.Element exposing (Element)
import Json.Decode exposing ((:=))
import Debug
import Color
import Signal
import Signal.Extra as Signal
import Mouse
import Keyboard exposing (KeyCode)
import Util exposing (..)
import Time
import Window
import Either exposing (Either(..))
import Html exposing (div)
import Html.Events exposing (onMouseDown, onClick, on, onKeyUp, onKeyDown)
import Html.Attributes exposing (style, type', attribute, href, rel, src, class)
import Slider exposing (slider)
import Set
import Native.Click
import Markdown

parseTwoFormExpression str =
  Expression.parse str `Result.andThen` \expr ->
    if List.all (\v -> v == coord1 || v == coord2) (Set.toList (Expression.variables expr))
    then Ok expr
    else Err "Unknown variable"

expressionEntry : String -> (String -> Signal.Message) -> Html.Html
expressionEntry content f =
  let
    valueDecoder =
      "target" := ("value" := Json.Decode.string)

    color =
      case parseTwoFormExpression content of
        Ok _ ->
          "white"
        _ ->
          "#DA7F7F"
  in
  Html.input
  [ type' "text"
  , style [("width", "108px"), ("backgroundColor", color)]
  , Html.Attributes.value content
  , on "input" valueDecoder f
  ]
  []

-- (a, b, c, d) is the matrix
-- a b
-- c d
type alias TwoForm = (Expression, Expression, Expression, Expression)

-- Begin geodesic equation stuff
christoffelFirst1 (g11, g12, g21, g22) =
  let
    gamma121 =
      Mul (Constant 0.5)
      -- TODO: Optimize. g12 = g21
        (Add (Mul (Constant -1) (derivative coord1 g12))
          (Add (derivative coord2 g11)
            (derivative coord1 g21)))
  in
  -- \Gamma_{11,1}
  ( Mul (Constant 0.5) (derivative coord1 g11)
  -- \Gamma_{12,1}
  , gamma121
  -- \Gamma_{21,1}
  , gamma121
  -- \Gamma_{22,1}
  , Add (derivative coord2 g21)
      (Mul (Constant -0.5) (derivative coord1 g22))
  )

christoffelFirst2 (g11, g12, g21, g22) =
  let
    gamma122 = Mul (Constant 0.5) (derivative coord1 g22)
  in
  -- \Gamma_{11,2}
  ( Add (derivative coord1 g12)
      (Mul (Constant -0.5) (derivative coord2 g11))
  -- \Gamma_{12,2}
  , gamma122
  -- \Gamma_{21,2}
  , gamma122
  -- \Gamma_{22,2}
  , Mul (Constant 0.5) (derivative coord2 g22)
  )

invert (g11, g12, g21, g22) =
  let c = Pow (Add (Mul g11 g22) (Mul (Constant -1) (Mul g12 g21))) -1
  in
  ( Mul c g22
  , Mul c (Mul (Constant -1) g12)
  , Mul c (Mul (Constant -1) g21)
  , Mul c g11
  )

christoffelSecond1 ((g11,g12,g21,g22) as g) =
  let (h11, h12, h21, h22) = invert g
      (gamma111, gamma121, gamma211, gamma221) = christoffelFirst1 g
      (gamma112, gamma122, gamma212, gamma222) = christoffelFirst2 g
      gammaSecond121 =
        sum [ Mul h11 gamma121, Mul h12 gamma122 ]
  in
  -- \Gamma_{11}^1
  ( sum [ Mul h11 gamma111, Mul h12 gamma112 ]
  -- \Gamma_{12}^1
  , gammaSecond121
  -- \Gamma_{21}^1
  , gammaSecond121
  -- \Gamma_{22}^1
  , sum [ Mul h11 gamma221, Mul h12 gamma222 ]
  )

christoffelSecond2 ((g11,g12,g21,g22) as g) =
  let (h11, h12, h21, h22) = invert g
      (gamma111, gamma121, gamma211, gamma221) = christoffelFirst1 g
      (gamma112, gamma122, gamma212, gamma222) = christoffelFirst2 g
      gammaSecond122 =
        sum [ Mul h21 gamma121, Mul h22 gamma122 ]
  in
  ( sum [ Mul h21 gamma111, Mul h22 gamma112 ]
  , gammaSecond122
  , gammaSecond122
  , sum [ Mul h21 gamma221, Mul h22 gamma222 ]
  )

geodesicSystem : TwoForm -> ODE.System
geodesicSystem g =
  let
    (gamma111,gamma121,gamma211, gamma221) = christoffelSecond1 g
    (gamma112,gamma122,gamma212, gamma222) = christoffelSecond2 g

    spec = Dict.fromList
      [ (coord1, Var dcoord1)
      , (coord2, Var dcoord2)
      , (dcoord1
        , Expression.optimize <| Mul (Constant -1) <| sum
          [ prod [ gamma111, Var dcoord1, Var dcoord1 ]
          , prod [ gamma121, Var dcoord1, Var dcoord2 ]
          , prod [ gamma211, Var dcoord2, Var dcoord1 ]
          , prod [ gamma221, Var dcoord2, Var dcoord2 ]
          ]
        )
      , (dcoord2
        , Expression.optimize <| Mul (Constant -1) <| sum
          [ prod [ gamma112, Var dcoord1, Var dcoord1 ]
          , prod [ gamma122, Var dcoord1, Var dcoord2 ]
          , prod [ gamma212, Var dcoord2, Var dcoord1 ]
          , prod [ gamma222, Var dcoord2, Var dcoord2 ]
          ]
        )
      ]
  in
  ODE.compile spec
-- End geodesic equation stuff

-- My, this is getting crufty.
type alias State =
  { system        : ODE.System
  , metric        : TwoForm -- Can precompile if this is slow
  , metricStrings : (String, String, String, String)
  , overlay       : Float -> Form
  , metricIndex   : Either Int TwoForm
  , currGeodesic  : ODE.Solution
  , nextGeodesic  : ODE.Solution
  -- Position (in length) along the current geodesic segment
  , geodesicPos   : Float
  , scaleFactor   : Float
  , pan           : (Float, Float)
  -- If we should leave a trail, this is Just t where t is where along
  -- the current geodesic we should start the trail. Otherwise it is Nothing
  , trailStart   : Maybe Float
  , trail        : List (List (Float, Float))
  , speed        : Float
  , turningSpeed : Float
  -- Should the keyboard input be used to control the arrow?
  , keysActive   : Bool
  -- Should the info box be displayed?
  , showInfo     : Bool
  }

-- Inputs
mouseDownsInSpaceDivBox : Signal.Mailbox ()
mouseDownsInSpaceDivBox = Signal.mailbox ()

toggleLeaveTrailBox : Signal.Mailbox ()
toggleLeaveTrailBox = Signal.mailbox ()

pans : Signal (Float, Float)
pans =
  let 
    mouseUps =
      Signal.filterMap (\d -> if d then Nothing else Just False) False Mouse.isDown

    dragging =
      Signal.merge mouseUps
        (Signal.map (\_ -> True) mouseDownsInSpaceDivBox.signal)
  in
  Signal.foldps (\(xi, yi) (prevX, prevY) ->
    let (x, y) = (toFloat xi, toFloat yi) in
    ((x - prevX, y - prevY), (x, y)))
    ((0, 0), (0, 0))
    Mouse.position
  |> Signal.keepWhen dragging (0, 0)

type Update
  = Keys {delta : Float, keys : { x : Int, y : Int }}
  | Pan (Float, Float)
  | ClearTrail
  | ToggleLeaveTrail
  | Zoom Float
  | SetScaleFactor Float
  | SetSpeed Float
  | SetTurningSpeed Float
  | SetMetric (Either Int TwoForm)
  | EditMetric (Bit, Bit) String
  | KeysActive Bool
  | ToggleInfo
  | NoOp

updateBox : Signal.Mailbox Update
updateBox = Signal.mailbox NoOp

keys : Signal { delta : Float, keys : { x : Int, y : Int } }
keys =
  let
    delta = Time.fps 30
  in
  Signal.sampleOn delta
    (Signal.map2 (\d k -> {delta=d, keys=k}) delta Keyboard.arrows)

updates : Signal Update
updates =
  Signal.mergeMany
  [ Signal.map Pan pans
  , Signal.map Keys keys
  , updateBox.signal
  , Signal.map KeysActive bodyFocused
  ]

currentDet : State -> Float
currentDet s =
  let
    (g11, g12, g21, g22) = s.metric
    -- I compute posAndVel just before in update. If it's slow I can cut reuse the computation.
    posAndVel = ODE.at s.currGeodesic s.geodesicPos
    {-
    x = getExn posAndVel coord1
    y = getExn posAndVel coord2 -}
    a11 = Expression.evaluateExn g11 posAndVel
    a12 = Expression.evaluateExn g12 posAndVel
    a21 = a12
    a22 = Expression.evaluateExn g22 posAndVel
  in
  a11 * a22 - a21 * a12

normAt : TwoForm -> (Float, Float) -> (Float, Float) -> Float
normAt metric (xPos, yPos) =
  let
    (g11, g12, g21, g22) = metric
    posEnv = Dict.fromList [(coord1, xPos), (coord2, yPos)]
    a11 = Expression.evaluateExn g11 posEnv
    a12 = Expression.evaluateExn g12 posEnv
    a21 = a12
    a22 = Expression.evaluateExn g22 posEnv
  in
  \(x, y) -> sqrt (x * (a11 * x + a12 * y) + y * (a21 * x + a22 * y))

currentNorm : State -> (Float, Float) -> Float
currentNorm s =
  let
    (g11, g12, g21, g22) = s.metric
    -- I compute posAndVel just before in update. If it's slow I can cut reuse the computation.
    posAndVel = ODE.at s.currGeodesic s.geodesicPos
    a11 = Expression.evaluateExn g11 posAndVel
    a12 = Expression.evaluateExn g12 posAndVel
    a21 = a12
    a22 = Expression.evaluateExn g22 posAndVel
  in
  \(x, y) -> sqrt (x * (a11 * x + a12 * y) + y * (a21 * x + a22 * y))

update : Update -> State -> State
update u s =
  case u of
    NoOp ->
      s

    ToggleInfo ->
      {s | showInfo <- not s.showInfo}

    KeysActive b ->
      {s | keysActive <- b}

    EditMetric ij str ->
      let
        metricStrings' =
          let (i,j) = ij in
          setAt (j,i) str (setAt ij str s.metricStrings)

        exprRess =
          List.map parseTwoFormExpression
            (fourToList metricStrings')
      in
      case sequenceResults exprRess of
        Err err -> -- Just sit tight
          {s | metricStrings <- metricStrings'}

        Ok m ->
          let metric' = fourFromList m
              system = geodesicSystem metric'
              init = ODE.at s.currGeodesic s.geodesicPos
              currGeodesic = ODE.solve 0 futureLength init system 0.000001 1000
          in
          { s
          | metric <- metric'
          , metricIndex <- Right metric' -- TODO: MetricIndex should really just be Maybe
          , metricStrings <- metricStrings'
          , overlay <- \_ -> group []
          , system <- system
          , trail <- geodesicPathFromTill 0 s.geodesicPos s.currGeodesic :: s.trail
          , trailStart <- Maybe.map (\_ -> 0) s.trailStart
          , currGeodesic <- currGeodesic
          , nextGeodesic <- ODE.solve 0 futureLength (ODE.at currGeodesic futureLength) system 0.000001 1000
          , geodesicPos <- 0
          }

    SetMetric ig ->
      let
        m =
          case ig of
            Right g ->
              { twoForm = g
              , init = ODE.at s.currGeodesic s.geodesicPos
              , name = "Custom"
              , scaleFactor = defaultScaleFactor
              , overlay = \_ -> group []
              , pan = defaultPan
              }

            Left i ->
              metricArray ! i

        system =
          geodesicSystem m.twoForm

        currGeodesic = ODE.solve 0 futureLength m.init system 0.000001 1000
      in
      { s
      | metric <- m.twoForm
      , metricStrings <- fourMap Expression.toString m.twoForm
      , metricIndex <- ig
      , overlay <- m.overlay
      , system <- system
      , trailStart <- Maybe.map (\_ -> 0) s.trailStart
      , currGeodesic <- currGeodesic
      , nextGeodesic <- ODE.solve 0 futureLength (ODE.at currGeodesic futureLength) system 0.000001 1000
      , geodesicPos <- 0
      , trail <- []
      , scaleFactor <- m.scaleFactor
      , pan <- m.pan
      }


    -- TODO: Zoom should fix the point the mouse is over
    Zoom z ->
      let scaleFactor' = s.scaleFactor * (1.01 ^ (-z))  in
      { s
      | scaleFactor <- scaleFactor'
      }

    Keys kd ->
      if s.keysActive then updateKeys kd s else s

    Pan (dx, dy) ->
      let (x, y) = s.pan in
      { s | pan <- (x + dx, y + dy) }

    ToggleLeaveTrail ->
      case s.trailStart of
        Nothing ->
          { s | trailStart <- Just s.geodesicPos }

        Just start ->
          let
            trail' =
              if s.geodesicPos > 0
              then 
                geodesicPathFromTill start s.geodesicPos s.currGeodesic
                :: s.trail
              else
                s.trail
          in
          { s | trail <- trail', trailStart <- Nothing }

    SetScaleFactor x ->
      { s | scaleFactor <- x }

    SetSpeed x ->
      { s | speed <- x }

    SetTurningSpeed x ->
      { s | turningSpeed <- x }

    ClearTrail ->
      let
        trailStart' = Maybe.map (\_ -> s.geodesicPos) s.trailStart
      in
      { s | trail <- [], trailStart <- trailStart' }

-- TODO change to pattern match on the record. Currently a syntax error (bug)
updateKeys : {delta : Float, keys : {x:Int, y:Int}} -> State -> State
updateKeys kd s =
  let dt           = kd.delta
      keys         = kd.keys
      rate         = 1 / 2000
      geodesicPos' = s.geodesicPos + s.speed * dt * toFloat (max keys.y 0)
  in
  if keys.x == 0
  then
  -- TODO: It's a bit suspect that I only refresh geodesicPos in here. Should also
  -- in the other branch, or less wastefully just turn before moving forward in the other branch.
    if geodesicPos' >= futureLength
    then
      let trail' =
        case s.trailStart of
          Nothing ->
            s.trail
          Just start ->
            geodesicPathFromTill start geodesicPos' s.currGeodesic
            :: s.trail
      in
      { s
      | geodesicPos <- geodesicPos' - futureLength
      , currGeodesic <- s.nextGeodesic
      , nextGeodesic <- ODE.solve 0 futureLength (ODE.at s.nextGeodesic futureLength) s.system 0.000001 1000
--      , currGeodesic <- ODE.solve 0 futureLength (ODE.at s.currGeodesic s.geodesicPos) s.system 0.000001 1000
      , trail <- trail'
      , trailStart <- Maybe.map (\_ -> 0) s.trailStart
      }
    else { s | geodesicPos <- geodesicPos' }
  else
    let
      posAndVel =
        ODE.at s.currGeodesic geodesicPos'

      (velX, velY) =
        (getExn dcoord1 posAndVel, getExn dcoord2 posAndVel)

      angle' = 
        atan2 velY velX + s.turningSpeed * (-1 * toFloat keys.x)

      -- possibly have to normalize this vector wrt to the metric to get
      -- a unit speed geodesic
      posAndVel' =
        let
          velX' = cos angle'
          velY' = sin angle'
          norm = currentNorm s (velX', velY')
        in
        Dict.insert dcoord1 (velX' / norm)
          (Dict.insert dcoord2 (velY' / norm) posAndVel)

      trail' =
        case s.trailStart of
          Nothing ->
            s.trail
          Just start ->
            if geodesicPos' > 0
            then geodesicPathFromTill start geodesicPos' s.currGeodesic :: s.trail
            else s.trail

      currGeodesic' =
        ODE.solve 0 futureLength posAndVel' s.system 0.000001 1000
    in
    { s
    | geodesicPos <- 0
    , currGeodesic <- currGeodesic'
    , nextGeodesic <- ODE.solve 0 futureLength (ODE.at currGeodesic' futureLength) s.system 0.000001 1000
    , trail <- trail'
    , trailStart <- Maybe.map (\_ -> 0) s.trailStart
    }

curvedArrow : State -> Form
curvedArrow s =
  let arrowLen = 0.5
      headLen = 0.3

      bodyLenFromCurr =
        let
          remainingOnCurr =
            futureLength - s.geodesicPos
        in
        min remainingOnCurr arrowLen

      bodyLenFromNext =
        arrowLen - bodyLenFromCurr

      headLenFromCurr =
        let
          remainingOnCurr =
            (futureLength - s.geodesicPos) - bodyLenFromCurr
        in
        min headLen remainingOnCurr

      headLenFromNext =
        headLen - headLenFromCurr

      dataFromTil start stop geo =
        let
          toRecord t dat =
            { t = t, x = getExn coord1 dat, y = getExn coord2 dat, dx = getExn dcoord1 dat, dy = getExn dcoord2 dat }
        in
        toRecord start (ODE.at geo start)
        ::
          (takeWhile (\d -> d.t <= stop)
            (dropWhile (\d -> d.t < start)
              (List.map2 toRecord (ODE.solutionParameters geo) (ODE.solutionValues geo))))
        ++ [ toRecord stop (ODE.at geo stop) ]

      bodyDatas =
        dataFromTil s.geodesicPos (s.geodesicPos + bodyLenFromCurr) s.currGeodesic
        ++ if bodyLenFromNext > 0 then dataFromTil 0 bodyLenFromNext s.nextGeodesic else []

      headPts =
        let 
          currStart = s.geodesicPos + bodyLenFromCurr
          dataFromCurr =
            if headLenFromCurr > 0
            then
              List.map (\d -> {d | t <- d.t - currStart})
                (dataFromTil currStart (currStart + headLenFromCurr) s.currGeodesic)
            else
              []

          dataFromNext =
            if headLenFromNext > 0
            then 
              List.map (\d -> {d | t <- d.t + headLenFromCurr - bodyLenFromNext})
                (dataFromTil bodyLenFromNext (bodyLenFromNext + headLenFromNext) s.nextGeodesic)
            else []

          datas =
            dataFromCurr ++ dataFromNext
            {-
            List.map (\d -> {d | t <- d.t - currStart}) dataFromCurr
            ++ List.map (\d -> {d | t <- d.t + headLenFromCurr}) dataFromNext -}

          offset dist sgn d =
            let {x,y,dx,dy,t} = d
                t' = 1 - t/headLen
            in
            ( s.scaleFactor * (x + t' * dist * sgn * -dy)
            , s.scaleFactor * (y + t' * dist * sgn * dx)
            )
        in
        List.map (offset 0.2 1) datas
        ++ revMap (offset 0.2 -1) datas
      
      offset d sgn dat =
        let {x,y,dx,dy} = dat
        in
        ( s.scaleFactor * (x + d * sgn * -dy)
        , s.scaleFactor * (y + d * sgn * dx)
        )

      pts =
        List.map (offset 0.1 1) bodyDatas
        ++ headPts
        ++ revMap (offset 0.1 -1) bodyDatas
  in
  filled Color.red (polygon pts)

drawSpace : State -> Form
drawSpace s =
  let posAndVel = ODE.at s.currGeodesic s.geodesicPos
      xReal = getExn coord1 posAndVel
      yReal = getExn coord2 posAndVel 
      x = s.scaleFactor * xReal
      y = s.scaleFactor * yReal
      dx = s.scaleFactor * getExn dcoord1 posAndVel
      dy = s.scaleFactor * getExn dcoord2 posAndVel
      (px, py) = s.pan
  in
  group
  [ s.overlay s.scaleFactor
  , case s.trailStart of
      Just start ->
        drawGeodesicFromTil
          s.scaleFactor start s.geodesicPos s.currGeodesic 
      Nothing ->
        group []
  , group
    (List.map
      (traced (solid Color.green) << path << List.map (\(x,y) -> (x*s.scaleFactor, y*s.scaleFactor)))
      s.trail)
  , curvedArrow s
  ]
  |> move (px, -py)

drawGeodesic : Float -> ODE.Solution -> Form
drawGeodesic scaleFactor sol =
  let
    pts =
      List.map (\e -> (scaleFactor * getExn coord1 e, scaleFactor * getExn coord2 e))
        (ODE.solutionValues sol)
  in
  traced (solid Color.red) (path pts)

drawGeodesicTil : Float -> Float -> ODE.Solution -> Form
drawGeodesicTil scaleFactor distance geodesic =
  let
    toPt e = (scaleFactor * getExn coord1 e, scaleFactor * getExn coord2 e)
    pts =
      List.map snd
        (takeWhile (\(t, pt) -> t <= distance)
          (List.map2 (\t e ->
            (t, toPt e))
            (ODE.solutionParameters geodesic)
            (ODE.solutionValues geodesic)))
        ++ [ toPt (ODE.at geodesic distance) ]
  in
  traced (solid Color.green) (path pts)

-- Pretty annoying that this is gonna get recomputed on every tick
geodesicPathFromTill : Float -> Float -> ODE.Solution -> List (Float, Float)
geodesicPathFromTill start stop geodesic =
  let
    toPt e =
      (getExn coord1 e, getExn coord2 e)
  in
  path (
  toPt (ODE.at geodesic start)
  ::
  List.map snd
    (takeWhile (\(t, _) -> t <= stop)
      (dropWhile (\(t, _) -> t < start)
        (List.map2 (\t e ->
          (t, toPt e))
          (ODE.solutionParameters geodesic)
          (ODE.solutionValues geodesic))))
    ++ [ toPt (ODE.at geodesic stop) ])

drawGeodesicFromTil : Float -> Float -> Float -> ODE.Solution -> Form
drawGeodesicFromTil scaleFactor start stop geodesic =
  let
    toPt e = (scaleFactor * getExn coord1 e, scaleFactor * getExn coord2 e)
    pts =
      toPt (ODE.at geodesic start)
      ::
      List.map snd
        (takeWhile (\(t, _) -> t <= stop)
          (dropWhile (\(t, _) -> t < start)
            (List.map2 (\t e ->
              (t, toPt e))
              (ODE.solutionParameters geodesic)
              (ODE.solutionValues geodesic))))
        ++ [ toPt (ODE.at geodesic stop) ]
  in
  traced (solid Color.green) (path pts)

draw : (Int, Int) -> State -> Element
draw (w, h) s =
  let
    labelSlider label sliderElt =
      div [ style [("textAlign", "center")] ]
      [ Html.text label
      , sliderElt
      ]

    mkCheckBox id label checked upd =
      Html.label
      [ class "mdl-checkbox mdl-js-checkbox mdl-js-ripple-effect"
      , Html.Attributes.for id
      ]
      [ Html.input
        ((if checked then [attribute "checked" ""] else []) ++
        [ type' "checkbox"
        , class "mdl-checkbox__input"
        , Html.Attributes.id id
        , onClick updateBox.address upd
        ])
        []
      , Html.span
        [ class "mdl-checkbox__label" ]
        [ Html.text label ]
      ]

    toggleTrailCheck =
      mkCheckBox "toggleTrailCheck" "Leave trail" (shouldLeaveTrail s) ToggleLeaveTrail

    clearTrailButton =
      Html.button
      [ onClick updateBox.address ClearTrail
      , class "mdl-button mdl-js-button mdl-button--raised mdl-js-ripple-effect mdl-button--colored"
      ]
      [ Html.text "Clear trail" ]

    speedSlider =
      slider { min = 0 , max = 10/2000, value = s.speed, step = Nothing}
        (Signal.message updateBox.address << SetSpeed)

    turningSpeedSlider =
      slider { min = pi/Time.second, max = 100*pi/Time.second, value = s.turningSpeed ,step = Nothing}
        (Signal.message updateBox.address << SetTurningSpeed)

    scaleFactorSlider =
      slider
        { min = 1, max = 1000, value = s.scaleFactor, step = Nothing }
        (Signal.message updateBox.address << SetScaleFactor)

    annoyingOffsetForSliders = px 26

    sideBarWidth =
      300

    signature =
      div
      [ style
        [ ("position", "fixed")
        , ("bottom", px 0)
        , ("left", px 4)
        ]
      ]
      [ Html.text "By Izzy Meckler" ]

    space =
      collage w h [drawSpace s]

    wrapSlider item =
      Html.li
      [ style
        [ ("paddingTop", px 10)
        , ("paddingBottom", px 10)
        ]
      ]
      [item]

    wrapNonSlider item =
      Html.li
      [ style
        [ ("paddingLeft", annoyingOffsetForSliders)
        , ("paddingTop", px 10), ("paddingBottom", px 10)
        ]
      ]
      [item]

    helpCard =
      let
        helpContent = """
Here, you can explore a variety of unusual geometries.
Roughly speaking, a geometry is a [notion of distances][0]
between points.
Though they look curved, the paths you travel
along are actually "straight lines"
in the sense that they are the shortest paths between points
(with respect to an unusual notion of distance).
Such paths are called [geodesics](https://en.wikipedia.org/wiki/Geodesic).

Use the up arrow key to go forward along the geodesic in the direction
you're facing and the left and right arrow keys to change direction.

Scroll to zoom, click and drag to pan.

Try out all the different geometries and make your own using
the text entries.

You can read an extended explanation [here](http://parametricity.com/posts/2015-07-28-visualizing-geometries.html).

[0]: https://en.wikipedia.org/wiki/Metric_(mathematics)
        """
      in
      div
      [ class "mdl-card mdl-shadow--2dp demo-card-square" 
      , style
        [ ("width", px sideBarWidth)
        , ("position", "fixed")
        , ("minHeight", px 0)
        , ("top", px 10)
        , ("left", px 10)
        ]
      ]
      ( div
        [ class "mdl-card__title mdl-button mdl-button--colored mdl-js-button mdl-js-ripple-effect" 
        , Html.Attributes.id "help-card-title"
        , style
          [ ("backgroundColor","#46B6AC")
          , ("color", "white")
          , ("height", px 52)
          ]
        , onClick updateBox.address ToggleInfo
        ]
        [ Html.h2
          [ class "mdl-card__title-text" ]
          [ Html.text "Info" ]
        ]
      ::
      if s.showInfo
      then
        [ div
          [ style [("padding", px 10)] ]
          [ Markdown.toHtml helpContent
          ]
        ]
      else [])

    customMetricEntry =
      Html.li
      [ style [("marginBottom", px 5)] ]

    metricCard =
      div
      [ class "mdl-card mdl-shadow--2dp demo-card-square" 
      , style [("width", "100%")]
      ]
      [ div
        [ class "mdl-card__title" 
        , style
          [ ("backgroundColor", "rgb(63, 81, 181)") 
          , ("color", "white")
          ]
        ]
        [ Html.h2 [ class "mdl-card__title-text" ]
          [ Html.text "Choose geometry" ]
        ]
      , div
        [ style [("paddingTop", px 15)] ]
        [ Html.ul
          [ style
            [ ("listStyleType", "none")
            , ("paddingLeft", px 18)
            ]
          ]
          (List.indexedMap (\i m ->
            Html.li
            [ style [("marginBottom", px 5)] ]
            [ Html.label
              [ onClick updateBox.address (SetMetric (Left i))
              , class "mdl-radio mdl-js-radio mdl-js-ripple-effect"
              , Html.Attributes.for ("metric" ++ toString i)
              ]
              [ Html.input
                ((if Left i == s.metricIndex then [attribute "checked" ""] else []) ++
                [ type' "radio"
                , Html.Attributes.id ("metric" ++ toString i)
                , class "mdl-radio__button"
                , Html.Attributes.name "metric"
                ]) 
                []
              , Html.span [ class "mdl-radio__label" ]
                [ Html.text m.name ]
              ]
            ])
            metricList
          ++
          let
            _ =
              case s.metricIndex of
                Right _ -> Native.Click.clickMomentarily "metric-custom" -- purity's overrated
                _ -> ()
          in
          [ Html.li
            [ style [("marginBottom", px 5)] ]
            [ Html.label
              [ onClick updateBox.address (SetMetric (Right s.metric))
              , class "mdl-radio mdl-js-radio mdl-js-ripple-effect"
              , Html.Attributes.for "metric-custom"
              ]
              [ Html.input
                [ type' "radio"
                , Html.Attributes.id "metric-custom"
                , class "mdl-radio__button"
                , Html.Attributes.name "metric"
                ]
                []
              , Html.span [ class "mdl-radio__label" ]
                [ Html.text "Custom" ]
              ]
            ]
          ]
          )
        , Html.table
          [ style
            [ ("borderTop", "1px solid #DDD")
            ]
          ]
          [ Html.tr []
            [ Html.td []
              [expressionEntry mstr00 (Signal.message updateBox.address << EditMetric (O,O))]
            , Html.td []
              [expressionEntry mstr01 (Signal.message updateBox.address << EditMetric (O,I))]
            ]
          , Html.tr []
            [ Html.td []
              [expressionEntry mstr10 (Signal.message updateBox.address << EditMetric (I,O))]
            , Html.td []
              [expressionEntry mstr11 (Signal.message updateBox.address << EditMetric (I,I))]
            ]
          ]
        ]
      ]

    (mstr00,mstr01,mstr10,mstr11) =
      s.metricStrings

    sideBar =
      Html.ul
      [ style
        [ ("width", px sideBarWidth) 
        , ("position", "fixed")
        , ("top", "10px")
        , ("right", "50px")
        , ("zIndex", "10")
        , ("listStyleType", "none")
        , ("padding", "0")
        , ("margin", "0")
        ]
      ]
      [ Html.li
        [ style
          [ ("paddingLeft", annoyingOffsetForSliders)
          , ("paddingRight", annoyingOffsetForSliders)
          ]
        ]
        [metricCard]
      , wrapNonSlider toggleTrailCheck
      , wrapNonSlider clearTrailButton
      , wrapSlider (labelSlider "Speed" speedSlider)
      , wrapSlider (labelSlider "Turn speed" turningSpeedSlider)
      ]
  in
  div [ style [("width", "100%")] ]
  [ Html.node "link"
    [ rel "stylesheet", href "https://storage.googleapis.com/code.getmdl.io/1.0.1/material.indigo-pink.min.css" ]
    []
  , Html.node "script"
    [ type' "text/javascript", src "https://storage.googleapis.com/code.getmdl.io/1.0.1/material.min.js" ]
    []
  , sideBar
  , helpCard
  , signature
  , div
    [ onMouseDown mouseDownsInSpaceDivBox.address () 
    {- TODO: Figure out wtf this isn't working
    , onKeyUp keyEventsBox.address (\k -> (k, False))
    , onKeyDown keyEventsBox.address (\k -> (k, True)) -}
    , on "wheel" ("deltaY" := Json.Decode.float) (\z ->
        Signal.message updateBox.address (Zoom z))
    , on "focusout" (Json.Decode.succeed ()) (\_ ->
        Debug.log "fuck your couch"
          (Signal.message updateBox.address (Zoom 0)))
    ]
    [ Html.fromElement space ]
  ]
  |> Html.toElement w h

defaultScaleFactor = 200
defaultPan = (0, 0)

fourMap : (a -> b) -> (a, a, a, a) -> (b, b, b, b)
fourMap f (a1,a2,a3,a4) = (f a1, f a2, f a3, f a4)

fourToList : (a, a, a, a) -> List a
fourToList (a1,a2,a3,a4) = [a1, a2, a3, a4]

fourFromList : List a -> (a,a,a,a)
fourFromList [a1,a2,a3,a4] = (a1,a2,a3,a4)

main =
  let
    system =
      geodesicSystem metric0.twoForm

    metric0 = metricArray ! 1

    init = metric0.init

    currGeodesic = ODE.solve 0 futureLength init system 0.000001 1000
    s0 =
      { geodesicPos = 0
      , system = system
      , metric = metric0.twoForm
      , metricStrings = fourMap Expression.toString metric0.twoForm
      , overlay = metric0.overlay
      , metricIndex = Left 1
      , currGeodesic = currGeodesic
      , nextGeodesic = ODE.solve 0 futureLength (ODE.at currGeodesic futureLength) system 0.000001 1000
      , scaleFactor = metric0.scaleFactor
      , pan = metric0.pan
      , trailStart = Just 0
      , trail = []
      , speed = 2 / 2000
      , turningSpeed = 30 * pi / Time.second
      , keysActive = True
      , showInfo = True
      }

    state =
      Signal.foldp update s0 updates
  in
  Signal.map2 draw
    Window.dimensions
    state

port bodyFocused : Signal Bool

-- UTILS

type Bit = O | I

sum (e::es) = List.foldl Add e es
prod (e::es) = List.foldl Mul e es

setAt : (Bit, Bit) -> a -> (a,a,a,a) -> (a,a,a,a)
setAt (x,y) a (a1,a2,a3,a4) =
  case (x, y) of
    (O, O) -> (a, a2, a3, a4)
    (O, I) -> (a1, a, a3, a4)
    (I, O) -> (a1, a2, a, a4)
    (I, I) -> (a1, a2, a3, a)

shouldLeaveTrail : State -> Bool
shouldLeaveTrail s =
  case s.trailStart of { Just _ -> True; _ -> False }

px x = toString x ++ "px"

closedCircle r =
  circle r ++ [(r, 0)]

-- CONFIG
futureLength = 1

coord1 = "x"
coord2 = "y"
dcoord1 = "dx"
dcoord2 = "dy"

metricArray = Array.fromList metricList

metricList =
  [ { name = "Upper half plane"
    , twoForm = halfPlane
    , init = Dict.fromList [(coord1, 0), (coord2, 2), (dcoord1, 1), (dcoord2, 0)]
    , overlay = \scaleFactor ->
        traced (dashed Color.black) (segment (-1000 * scaleFactor, 0) (1000 * scaleFactor, 0))
    , scaleFactor = defaultScaleFactor / 2
    , pan = (0, defaultScaleFactor)
    }
  , { name = "Poincare disk"
    , twoForm = poincare
    , init = Dict.fromList [(coord1, 0.5), (coord2, 0), (dcoord1, 0), (dcoord2, 1)]
    , overlay = \scaleFactor ->
        traced (dashed Color.black) (closedCircle scaleFactor)
    , scaleFactor = 2 * defaultScaleFactor
    , pan = defaultPan
    }
  , { name = "Klein disk"
    , twoForm = klein
    , init = Dict.fromList [(coord1, 0.5), (coord2, 0), (dcoord1, 0), (dcoord2, 1)]
    , overlay = \scaleFactor ->
        traced (dashed Color.black) (closedCircle scaleFactor)
    , scaleFactor = 2 * defaultScaleFactor
    , pan = defaultPan
    }
  , { name = "Strip sphere"
    , twoForm = sphere
    , init = Dict.fromList [(coord1, pi), (coord2, pi/2), (dcoord1, -0.04), (dcoord2, 1)]
    , overlay = \scaleFactor ->
        let x1 = 2 * pi * scaleFactor in let y1 = pi * scaleFactor in
        traced (dashed Color.black)
          (path [(0, 0), (x1, 0), (x1, y1), (0, y1), (0, 0)])
    , scaleFactor = defaultScaleFactor
    , pan = (-pi*defaultScaleFactor, pi*defaultScaleFactor/2)
    }
  , { name = "Stereographic sphere"
    , twoForm = stereoGraphicSphere
    , init = Dict.fromList [(coord1, 1.1085813794088752), (coord2, 0.43416503851501376), (dcoord1, 1.0618525452786418), (dcoord2, 0.3927089533282449)]
    , overlay = cylinderOverlay
    , scaleFactor = 66.27618564857013
    , pan = defaultPan
    }
  , { name = "Cylinder"
    , twoForm = cylinder
    , init = Dict.fromList [(coord1, 0.5), (coord2, 0), (dcoord1, 0), (dcoord2, 1)]
    , scaleFactor = defaultScaleFactor
    , pan = defaultPan
    , overlay = cylinderOverlay
    }
  , { name = "Flat"
    , twoForm = flat
    , init = Dict.fromList [(coord1, 0), (coord2, 1), (dcoord1, 1), (dcoord2, 0)]
    , overlay = \_ -> group []
    , scaleFactor = defaultScaleFactor
    , pan = defaultPan
    }
  {-
  , { name = "Curvy"
    , twoForm = curvy
    , init = Dict.fromList [(coord1, 0.5), (coord2, 1), (dcoord1, 0), (dcoord2, 1)]
    , overlay = \_ -> group []
    , scaleFactor = defaultScaleFactor
    , pan = defaultPan
    }
  -}
  ]
  |> List.map (\m ->
    let ((dx, dy) as v) = (getExn dcoord1 m.init, getExn dcoord2 m.init)
        pos = (getExn coord1 m.init, getExn coord2 m.init)
        norm = normAt m.twoForm pos v
        init' = Dict.insert dcoord1 (dx / norm) (Dict.insert dcoord2 (dy / norm) m.init)
    in
    { m | init <- init' })

cylinderOverlay scaleFactor =
  let nRays = 8 in
  group
  [ group
    (List.map (\i -> traced (dashed Color.black) (closedCircle (i * scaleFactor)))
      [1..10])
  , group
    (List.map (\i ->
      let t = i * 2 * pi / nRays in
      traced (dashed Color.black)
        (segment (0,0) (10 * scaleFactor * cos t, 10 * scaleFactor * sin t)))
      [1..nRays])
  ]


sphere =
  ( Pow (Sin (Var coord2)) 2
  , Constant 0
  , Constant 0
  , Constant 1
  )

stereoGraphicSphere =
  let
    x = Var coord1
    y = Var coord2
    r2 = Add (Mul x x) (Mul y y)
    c = Mul (Constant 4) (Pow (Add (Constant 1) r2) -2)
  in
  ( c, Constant 0, Constant 0, c )

flat = (Constant 1, Constant 0, Constant 0 , Constant 1)

poincare =
  let
    c =
      Pow
        (sum
        [ Constant 1
        , Mul (Constant -1)
            (Add (Mul (Var coord1) (Var coord1)) (Mul (Var coord2) (Var coord2)))
        ])
        -2
  in
  (c, Constant 0, Constant 0, c)

klein =
  let
    (x, y) = (Var coord1, Var coord2)
    c =
      sum
      [ Constant 1
      , Mul (Constant -1) 
        (Add (Mul x x) (Mul y y))
      ]
  in
  ( Add (Pow c -1) (Mul (Mul x x) (Pow c -2))
  , Mul (Mul x y) (Pow c -2)
  , Mul (Mul x y) (Pow c -2)
  , Add (Pow c -1) (Mul (Mul y y) (Pow c -2))
  )

halfPlane =
  let c = Pow (Var coord2) -2 in
  (c, Constant 0, Constant 0, c)

-- seems like everything gets you something similar
noparabola =
  let
    c =
      Pow
      (Add (Var coord2) (Mul (Constant -1) (Mul (Var coord1) (Var coord1))))
      -1
  in
  (c, Constant 0, Constant 0, c)

-- this is a nice one
curvy =
  let
    c =
      Pow
      (Add (Mul (Var coord2) (Var coord2)) (Mul (Var coord1) (Var coord1)))
      2
  in
  (c, Constant 0, Constant 0, c)

cylinder =
  let
    x = Var coord1
    y = Var coord2
    c = Pow (Add (Mul x x) (Mul y y)) -1
  in
  ( c, Constant 0
  , Constant 0, c )

{-
-- p(x,y) = let r = sqrt (x^2 + y^2) in (x / r, y / r, log r)
-- Correct but slow since the generated expression is huge.
cylinder =
  let 
    x = Var coord1
    y = Var coord2
    r = Pow (Add (Mul x x) (Mul y y)) 0.5
    p = [ Mul x (Pow r -1), Mul y (Pow r -1), LogBase e r ]
    dot l1 l2 = sum (List.map2 Mul l1 l2)
  in
  ( dot (List.map (derivative coord1) p) (List.map (derivative coord1) p)
  , dot (List.map (derivative coord1) p) (List.map (derivative coord2) p)
  , dot (List.map (derivative coord2) p) (List.map (derivative coord1) p)
  , dot (List.map (derivative coord2) p) (List.map (derivative coord2) p)
  )
-}
