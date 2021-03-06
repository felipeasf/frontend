module Page.Community.Objectives exposing (Model, Msg, init, msgToString, update, view)

import Api.Graphql
import Cambiatus.Enum.VerificationType as VerificationType exposing (VerificationType)
import Community exposing (Community, communityQuery)
import Eos exposing (Symbol)
import Graphql.Http
import Html exposing (..)
import Html.Attributes exposing (class, classList, disabled)
import Html.Events exposing (onClick)
import I18Next exposing (Delims(..), Translations, t)
import Icons
import Page
import Profile
import Route
import Session.LoggedIn as LoggedIn exposing (External(..))
import Strftime
import Task
import Time exposing (Posix, posixToMillis)
import UpdateResult as UR
import Utils


init : LoggedIn.Model -> Symbol -> ( Model, Cmd Msg )
init { shared } symbol =
    ( initModel symbol
    , Cmd.batch
        [ Api.Graphql.query shared (Community.communityQuery symbol) CompletedLoad
        , Task.perform GotTime Time.now
        ]
    )



-- MODEL


type alias Model =
    { communityId : Symbol
    , status : Status
    , openObjective : Maybe Int
    , date : Maybe Posix
    }


initModel : Symbol -> Model
initModel symbol =
    { communityId = symbol
    , status = Loading
    , openObjective = Nothing
    , date = Nothing
    }


type Status
    = Loading
    | Loaded Community
    | NotFound
    | Failed (Graphql.Http.Error (Maybe Community))



-- VIEW


view : LoggedIn.Model -> Model -> Html Msg
view ({ shared } as loggedIn) model =
    case model.status of
        Loading ->
            Page.fullPageLoading

        NotFound ->
            Page.viewCardEmpty [ text "Community not found" ]

        Failed e ->
            Page.fullPageGraphQLError (t shared.translations "community.objectives.title_plural") e

        Loaded community ->
            div []
                [ Page.viewHeader loggedIn (t shared.translations "community.objectives.title_plural") (Route.Community model.communityId)
                , div [ class "container mx-auto px-4 my-10" ]
                    [ div [ class "flex justify-end mb-10" ] [ viewNewObjectiveButton loggedIn community ]
                    , div []
                        (community.objectives
                            |> List.sortBy .id
                            |> List.reverse
                            |> List.indexedMap (viewObjective loggedIn model community)
                        )
                    ]
                ]


viewNewObjectiveButton : LoggedIn.Model -> Community -> Html msg
viewNewObjectiveButton ({ shared } as loggedIn) community =
    if LoggedIn.isAccount community.creator loggedIn then
        a
            [ class "button button-primary button-sm w-full md:w-64"
            , Route.href (Route.NewObjective community.symbol)
            ]
            [ text (t shared.translations "community.objectives.new") ]

    else
        text ""


viewObjective : LoggedIn.Model -> Model -> Community -> Int -> Community.Objective -> Html Msg
viewObjective ({ shared } as loggedIn) model community index objective =
    let
        canEdit : Bool
        canEdit =
            LoggedIn.isAccount community.creator loggedIn

        isOpen : Bool
        isOpen =
            case model.openObjective of
                Just obj ->
                    obj == index

                Nothing ->
                    False

        text_ s =
            text (t shared.translations s)
    in
    div [ class "p-4 sm:px-6 bg-white rounded mt-4" ]
        [ div [ class "flex justify-between items-start" ]
            [ div []
                [ p [ class "text-sm" ] [ text objective.description ]
                , p [ class "text-gray-900 text-caption uppercase mt-2" ]
                    [ text
                        (I18Next.tr shared.translations
                            Curly
                            "community.objectives.action_count"
                            [ ( "actions", objective.actions |> List.length |> String.fromInt ) ]
                        )
                    ]
                ]
            , div [ class "flex" ]
                [ a
                    [ class "w-full button button-secondary button-sm mr-10 hidden md:flex md:visible"
                    , Route.href (Route.EditObjective model.communityId objective.id)
                    ]
                    [ text_ "menu.edit" ]
                , button [ onClick (OpenObjective index) ]
                    [ if isOpen then
                        Icons.arrowDown "rotate-180"

                      else
                        Icons.arrowDown ""
                    ]
                ]
            ]
        , if isOpen then
            div []
                [ a
                    [ class "w-full button button-primary button-sm mt-6 mb-8"
                    , Route.href
                        (Route.NewAction community.symbol objective.id)
                    ]
                    [ text_ "community.actions.new" ]
                , div []
                    (objective.actions
                        |> List.map (viewAction loggedIn model objective.id)
                    )
                , a
                    [ class "w-full button button-secondary button-sm"
                    , Route.href (Route.EditObjective model.communityId objective.id)
                    ]
                    [ text_ "menu.edit" ]
                ]

          else
            text ""
        , if not isOpen then
            div [ class "flex items-center justify-end mt-8 md:hidden" ]
                [ a
                    [ class "w-full button button-secondary button-sm"
                    , Route.href (Route.EditObjective model.communityId objective.id)
                    ]
                    [ text_ "menu.edit" ]
                ]

          else
            text ""
        ]


viewAction : LoggedIn.Model -> Model -> Int -> Community.Action -> Html Msg
viewAction ({ shared } as loggedIn) model objectiveId action =
    let
        posixDeadline : Posix
        posixDeadline =
            action.deadline
                |> Utils.posixDateTime

        deadlineStr : String
        deadlineStr =
            posixDeadline
                |> Strftime.format "%d %B %Y" Time.utc

        pastDeadline : Bool
        pastDeadline =
            case action.deadline of
                Just deadline ->
                    case model.date of
                        Just today ->
                            posixToMillis today > posixToMillis posixDeadline

                        Nothing ->
                            False

                Nothing ->
                    False

        ( usages, usagesLeft ) =
            ( String.fromInt action.usages, String.fromInt action.usagesLeft )

        isClosed =
            pastDeadline || (action.usages > 0 && action.usagesLeft == 0)

        validationType =
            action.verificationType
                |> VerificationType.toString

        text_ s =
            text (t shared.translations s)

        tr r_id replaces =
            I18Next.tr loggedIn.shared.translations I18Next.Curly r_id replaces
    in
    div [ class "bg-gray-100 my-8 p-4" ]
        [ Icons.flag "mx-auto mb-4"
        , p [ class "text-body" ] [ text action.description ]
        , div [ class "flex flex-wrap my-6 -mx-2 items-center" ]
            [ div [ class "mx-2 mb-2" ]
                [ p [ class "input-label" ]
                    [ text_ "community.actions.reward" ]
                , p [ class "uppercase text-body" ]
                    [ String.fromFloat action.reward
                        ++ " "
                        ++ Eos.symbolToString model.communityId
                        |> text
                    ]
                ]
            , if validationType == "CLAIMABLE" then
                div [ class "mx-2 mb-2" ]
                    [ p [ class "input-label" ]
                        [ text_ "community.actions.validation_reward" ]
                    , p [ class "uppercase text-body" ]
                        [ String.fromFloat action.verificationReward
                            ++ " "
                            ++ Eos.symbolToString model.communityId
                            |> text
                        ]
                    ]

              else
                text ""
            , if action.deadline == Nothing && action.usages == 0 then
                text ""

              else
                div [ class "mx-2 mb-2" ]
                    [ p [ class "input-label" ]
                        [ text_ "community.actions.available_until" ]
                    , p [ class "text-body" ]
                        [ if action.usages > 0 then
                            p [ classList [ ( "text-red", action.usagesLeft == 0 ) ] ]
                                [ text (tr "community.actions.usages" [ ( "usages", usages ), ( "usagesLeft", usagesLeft ) ]) ]

                          else
                            text ""
                        , case action.deadline of
                            Just d ->
                                p [ classList [ ( "text-red", pastDeadline ) ] ] [ text deadlineStr ]

                            Nothing ->
                                text ""
                        ]
                    ]
            , div [ class "mx-2 mb-2" ]
                [ if action.isCompleted then
                    div [ class "tag bg-green" ] [ text_ "community.actions.completed" ]

                  else if isClosed then
                    div [ class "tag bg-gray-500 text-red" ] [ text_ "community.actions.closed" ]

                  else
                    text ""
                ]
            ]
        , div [ class "flex justify-between items-end py-8 flex-col" ]
            [ div [ class "w-full" ]
                [ p [ class "input-label mb-4" ] [ text_ "community.actions.verifiers" ]
                , if validationType == "AUTOMATIC" then
                    div [ class "flex items-center" ]
                        [ p [ class "text-body" ] [ text_ "community.actions.automatic_analyzers" ]
                        , Icons.exclamation "ml-2"
                        ]

                  else
                    div [ class "flex overflow-scroll -mx-2" ]
                        (List.map
                            (\u ->
                                div [ class "mx-2" ]
                                    [ Profile.view shared.endpoints.ipfs loggedIn.accountName shared.translations u ]
                            )
                            action.validators
                        )
                ]
            , a
                [ class "button button-secondary button-sm w-full mt-16"
                , Route.href (Route.EditAction model.communityId objectiveId action.id)
                ]
                [ text_ "menu.edit" ]
            ]
        ]



-- UPDATE


type alias UpdateResult =
    UR.UpdateResult Model Msg (External Msg)


type Msg
    = CompletedLoad (Result (Graphql.Http.Error (Maybe Community)) (Maybe Community))
    | GotTime Posix
    | OpenObjective Int


update : Msg -> Model -> LoggedIn.Model -> UpdateResult
update msg model _ =
    case msg of
        CompletedLoad (Ok community) ->
            case community of
                Just cmm ->
                    UR.init { model | status = Loaded cmm }

                Nothing ->
                    UR.init { model | status = NotFound }

        CompletedLoad (Err error) ->
            { model | status = Failed error }
                |> UR.init
                |> UR.logGraphqlError msg error

        GotTime date ->
            UR.init { model | date = Just date }

        OpenObjective index ->
            if model.openObjective == Just index then
                { model | openObjective = Nothing }
                    |> UR.init

            else
                { model | openObjective = Just index }
                    |> UR.init


msgToString : Msg -> List String
msgToString msg =
    case msg of
        CompletedLoad r ->
            [ "CompletedLoad", UR.resultToString r ]

        GotTime _ ->
            [ "GotTime" ]

        OpenObjective _ ->
            [ "OpenObjective" ]
