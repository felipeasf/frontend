module Page.Community exposing
    ( Model
    , Msg
    , init
    , jsAddressToMsg
    , msgToString
    , subscriptions
    , update
    , view
    )

import Api.Graphql
import Avatar
import Cambiatus.Enum.VerificationType as VerificationType
import Cambiatus.Object
import Cambiatus.Query exposing (ClaimsRequiredArguments)
import Cambiatus.Scalar exposing (DateTime(..))
import Community exposing (ActionVerification, ActionVerificationsResponse, ClaimResponse, Community)
import Dict exposing (Dict)
import Eos exposing (Symbol)
import Eos.Account as Eos
import Graphql.Http
import Graphql.Operation exposing (RootQuery)
import Graphql.OptionalArgument exposing (OptionalArgument(..))
import Graphql.SelectionSet as SelectionSet exposing (SelectionSet, with)
import Html exposing (Html, a, button, div, hr, img, p, span, text)
import Html.Attributes exposing (class, classList, disabled, placeholder, src)
import Html.Events exposing (onClick)
import I18Next exposing (t, tr)
import Icons
import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)
import Page
import Route
import Session.LoggedIn as LoggedIn exposing (External(..))
import Session.Shared exposing (Shared)
import Strftime
import Task
import Time exposing (Posix, posixToMillis)
import Transfer exposing (Transfer)
import UpdateResult as UR
import Utils
import View.Tag as Tag



-- INIT


init : LoggedIn.Model -> Symbol -> ( Model, Cmd Msg )
init ({ shared } as loggedIn) symbol =
    ( initModel loggedIn symbol
    , Cmd.batch
        [ Api.Graphql.query shared (Community.communityQuery symbol) CompletedLoadCommunity
        , fetchCommunityActions shared symbol
        , Task.perform GotTime Time.now
        ]
    )


fetchCommunityActions : Shared -> Symbol -> Cmd Msg
fetchCommunityActions shared sym =
    let
        stringSymbol : String
        stringSymbol =
            Eos.symbolToString sym

        selectionSet : SelectionSet ActionVerificationsResponse RootQuery
        selectionSet =
            verificationHistorySelectionSet stringSymbol
    in
    Api.Graphql.query
        shared
        selectionSet
        CompletedLoadActions



-- Actions SelectionSet


verificationHistorySelectionSet : String -> SelectionSet ActionVerificationsResponse RootQuery
verificationHistorySelectionSet stringSym =
    let
        vInput : ClaimsRequiredArguments
        vInput =
            { input = { validator = Absent, claimer = Absent, symbol = Present stringSym } }

        selectionSet : SelectionSet ClaimResponse Cambiatus.Object.Claim
        selectionSet =
            Community.claimSelectionSet stringSym
    in
    SelectionSet.succeed ActionVerificationsResponse
        |> with (Cambiatus.Query.claims vInput selectionSet)



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- MODEL


type alias Model =
    { date : Maybe Posix
    , community : LoadStatus
    , members : List Member
    , openObjective : Maybe Int
    , modalStatus : ModalStatus
    , messageStatus : MessageStatus
    , actions : Maybe ActionVerificationsResponse
    , invitations : String
    , symbol : Symbol
    }


initModel : LoggedIn.Model -> Symbol -> Model
initModel _ symbol =
    { date = Nothing
    , community = Loading
    , members = []
    , openObjective = Nothing
    , modalStatus = Closed
    , messageStatus = None
    , actions = Nothing
    , invitations = ""
    , symbol = symbol
    }


type LoadStatus
    = Loading
    | Loaded Community EditStatus
    | NotFound
    | Failed (Graphql.Http.Error (Maybe Community))


type EditStatus
    = NoEdit
    | OpenObjective Int


type SaveStatus
    = NotAsked
    | Saving
    | SaveFailed (Dict String FormError)


type ModalStatus
    = Opened Bool Int -- Action id
    | Closed


type MessageStatus
    = None
    | Success String
    | Failure String


type alias ObjectiveForm =
    { description : String
    , save : SaveStatus
    }


type Verification
    = Manually
    | Automatically


type FormError
    = Required
    | TooShort Int
    | TooLong Int
    | InvalidChar Char
    | AlreadyTaken
    | NotMember


type alias Member =
    { id : String
    , accountName : String
    , nameWithAt : String
    }



-- VIEW


view : LoggedIn.Model -> Model -> Html Msg
view loggedIn model =
    let
        t s =
            I18Next.t loggedIn.shared.translations s

        tr r_id replaces =
            I18Next.tr loggedIn.shared.translations I18Next.Curly r_id replaces

        text_ s =
            text (t s)
    in
    case model.community of
        Loading ->
            Page.fullPageLoading

        NotFound ->
            Page.viewCardEmpty [ text "Community not found" ]

        Failed e ->
            Page.fullPageGraphQLError (t "community.objectives.title") e

        Loaded community editStatus ->
            let
                canEdit =
                    LoggedIn.isAccount community.creator loggedIn
            in
            div []
                [ viewHeader loggedIn community
                , div [ class "bg-white p-20" ]
                    [ div [ class "flex flex-wrap w-full items-center" ]
                        [ p [ class "text-4xl font-bold" ]
                            [ text community.title ]
                        ]
                    , p [ class "text-grey-200 text-sm" ] [ text community.description ]
                    ]
                , div [ class "container mx-auto px-4" ]
                    [ viewClaimModal loggedIn model
                    , viewMessageStatus loggedIn model
                    , if canEdit then
                        div [ class "flex justify-between items-center py-2 px-8 sm:px-6 bg-white rounded-lg mt-4" ]
                            [ div []
                                [ p [ class "font-bold" ] [ text_ "community.objectives.title_plural" ]
                                , p [ class "text-gray-900 text-caption uppercase" ]
                                    [ text
                                        (tr "community.objectives.subtitle"
                                            [ ( "objectives", List.length community.objectives |> String.fromInt )
                                            , ( "actions"
                                              , List.map (\c -> List.length c.actions) community.objectives
                                                    |> List.foldl (+) 0
                                                    |> String.fromInt
                                              )
                                            ]
                                        )
                                    ]
                                ]
                            , a
                                [ class "button button-primary"
                                , Route.href (Route.Objectives community.symbol)
                                ]
                                [ text_ "menu.edit" ]
                            ]

                      else
                        text ""
                    , div [ class "bg-white py-6 sm:py-8 px-3 sm:px-6 rounded-lg mt-4" ]
                        ([ Page.viewTitle (t "community.objectives.title_plural") ]
                            ++ List.indexedMap (viewObjective loggedIn model community)
                                community.objectives
                            ++ [ if canEdit then
                                    viewObjectiveNew loggedIn editStatus community.symbol

                                 else
                                    text ""
                               ]
                        )

                    -- , Transfer.getTransfers (Just community)
                    --     |> viewSections loggedIn model
                    ]
                ]



-- VIEW VERIFICATIONS


viewVerification : Shared -> ActionVerification -> Html Msg
viewVerification shared verification =
    let
        maybeLogo =
            if String.isEmpty verification.logo then
                Nothing

            else
                Just (shared.endpoints.ipfs ++ "/" ++ verification.logo)

        description =
            verification.description

        date =
            Just verification.createdAt
                |> Utils.posixDateTime
                |> Strftime.format "%d %b %Y" Time.utc

        status =
            verification.status

        route =
            case verification.symbol of
                Just symbol ->
                    Route.VerifyClaim
                        symbol
                        verification.objectiveId
                        verification.actionId
                        verification.claimId

                Nothing ->
                    Route.ComingSoon
    in
    a
        [ class "border-b last:border-b-0 border-gray-500 flex items-start lg:items-center hover:bg-gray-100 first-hover:rounded-t-lg last-hover:rounded-b-lg p-4"
        , Route.href route
        ]
        [ div
            [ class "flex-none" ]
            [ case maybeLogo of
                Just logoUrl ->
                    img
                        [ class "w-10 h-10 object-scale-down"
                        , src logoUrl
                        ]
                        []

                Nothing ->
                    div
                        [ class "w-10 h-10 object-scale-down" ]
                        []
            ]
        , div
            [ class "flex-col flex-grow-1 pl-4" ]
            [ p
                [ class "font-sans text-black text-sm leading-relaxed" ]
                [ text description ]
            , p
                [ class "font-normal font-sans text-gray-900 text-caption uppercase" ]
                [ text date ]
            , div
                [ class "lg:hidden mt-4" ]
                [ Tag.view status shared.translations ]
            ]
        , div
            [ class "hidden lg:visible lg:flex lg:flex-none pl-4" ]
            [ Tag.view status shared.translations ]
        ]



-- VIEW OBJECTIVE


viewObjective : LoggedIn.Model -> Model -> Community -> Int -> Community.Objective -> Html Msg
viewObjective loggedIn model metadata index objective =
    let
        canEdit =
            LoggedIn.isAccount metadata.creator loggedIn

        isOpen : Bool
        isOpen =
            case model.openObjective of
                Just obj ->
                    obj == index

                Nothing ->
                    False

        arrowStyle : String
        arrowStyle =
            if canEdit then
                " sm:flex-grow-2"

            else
                " "

        actsNButton : List (Html Msg)
        actsNButton =
            List.map (viewAction loggedIn metadata model.date) objective.actions
                |> List.intersperse (hr [ class "bg-border-grey text-border-grey" ] [])
    in
    div [ class "my-2" ]
        [ div
            [ class "px-3 py-4 bg-body-blue flex flex-col sm:flex-row sm:items-center sm:h-10"
            ]
            [ div [ class "sm:flex-grow-7 sm:w-5/12" ]
                [ div
                    [ class "truncate overflow-hidden whitespace-no-wrap text-white font-medium text-sm overflow-hidden sm:flex-grow-8 sm:leading-normal sm:text-lg"
                    , if isOpen then
                        onClick ClickedCloseObjective

                      else
                        onClick (ClickedOpenObjective index)
                    ]
                    [ text objective.description ]
                ]
            , div [ class ("flex flex-row justify-end mt-5 sm:mt-0" ++ arrowStyle) ]
                [ button
                    [ class ""
                    , if isOpen then
                        onClick ClickedCloseObjective

                      else
                        onClick (ClickedOpenObjective index)
                    ]
                    [ img
                        [ class "fill-current text-white h-2 w-4 stroke-current"
                        , src "/icons/objective_arrow.svg"
                        , classList [ ( "rotate-180", isOpen ) ]
                        ]
                        []
                    ]
                ]
            ]
        , if isOpen then
            div [ class "pt-5 px-3 pb-3 sm:px-6 bg-white rounded-b-lg border-solid border-grey border" ]
                actsNButton

          else
            text ""
        ]


viewObjectiveNew : LoggedIn.Model -> EditStatus -> Symbol -> Html Msg
viewObjectiveNew loggedIn edit communityId =
    let
        t s =
            I18Next.t loggedIn.shared.translations s
    in
    a
        [ class "border border-dashed border-button-orange mt-6 w-full flex flex-row content-start px-4 py-2"
        , Route.href (Route.NewObjective communityId)
        , disabled (edit /= NoEdit)
        ]
        [ span [ class "px-2 text-button-orange font-medium" ] [ text "+" ]
        , span [ class "text-button-orange font-medium" ] [ text (t "community.objectives.new") ]
        ]



-- VIEW ACTION


viewAction : LoggedIn.Model -> Community -> Maybe Posix -> Community.Action -> Html Msg
viewAction loggedIn metadata maybeDate action =
    let
        t s =
            I18Next.t loggedIn.shared.translations s

        text_ s =
            text (t s)

        canEdit =
            LoggedIn.isAccount metadata.creator loggedIn

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
                Just _ ->
                    case maybeDate of
                        Just today ->
                            posixToMillis today > posixToMillis posixDeadline

                        Nothing ->
                            False

                Nothing ->
                    False

        rewardStrike : String
        rewardStrike =
            if pastDeadline || (action.usagesLeft < 1 && action.usages > 0) then
                " line-through"

            else
                ""

        dateColor : String
        dateColor =
            if pastDeadline then
                " text-date-red"

            else
                " text-date-purple"

        usagesColor : String
        usagesColor =
            if action.usagesLeft >= 1 || action.usages == 0 then
                " text-date-purple"

            else
                " text-date-red"

        ( claimColors, claimText ) =
            if pastDeadline || (action.usagesLeft < 1 && action.usages > 0) then
                ( " text-text-grey bg-grey cursor-not-allowed", "dashboard.closed" )

            else
                ( " text-white bg-button-orange", "dashboard.claim" )

        claimSize =
            if canEdit then
                " w-4/5"

            else
                " w-1/2"

        ipfsUrl =
            loggedIn.shared.endpoints.ipfs

        validatorAvatars =
            List.take 3 action.validators
                |> List.indexedMap
                    (\vIndex v ->
                        let
                            margin =
                                if vIndex /= 0 then
                                    " -ml-5"

                                else
                                    ""
                        in
                        ("h-10 w-10 border-white border-4 rounded-full bg-white" ++ margin)
                            |> Avatar.view ipfsUrl v.avatar
                    )
                |> (\vals ->
                        let
                            numValidators =
                                List.length action.validators
                        in
                        if numValidators > 3 then
                            vals
                                ++ [ div
                                        [ class "h-10 w-10 flex flex-col border-white border-4 bg-grey rounded-full -ml-5" ]
                                        [ p [ class "text-date-purple m-auto text-xs font-black leading-none tracking-wide" ]
                                            [ text ("+" ++ String.fromInt (numValidators - 3)) ]
                                        ]
                                   ]

                        else
                            vals
                   )

        rewardStr =
            String.fromFloat action.reward ++ " " ++ Eos.symbolToString metadata.symbol

        ( usages, usagesLeft ) =
            ( String.fromInt action.usages, String.fromInt action.usagesLeft )

        tr r_id replaces =
            I18Next.tr loggedIn.shared.translations I18Next.Curly r_id replaces

        validationType : String
        validationType =
            action.verificationType
                |> VerificationType.toString
    in
    if action.isCompleted then
        text ""

    else
        div [ class "py-6 px-2" ]
            [ div [ class "flex flex-col border-l-8 border-light-grey rounded-l-sm pl-2 sm:pl-6" ]
                [ span [ class "text-text-grey text-sm sm:text-base" ]
                    [ text action.description ]
                , div [ class "flex flex-col sm:flex-row sm:items-center sm:justify-between" ]
                    [ div [ class "text-xs mt-5 sm:w-1/3" ]
                        [ case action.deadline of
                            Just _ ->
                                div []
                                    [ span [ class "capitalize text-text-grey" ] [ text_ "community.actions.available_until" ]
                                    , span [ class dateColor ] [ text deadlineStr ]
                                    , span [] [ text_ "community.actions.or" ]
                                    ]

                            Nothing ->
                                text ""
                        , if action.usages > 0 then
                            p [ class usagesColor ]
                                [ text (tr "community.actions.usages" [ ( "usages", usages ), ( "usagesLeft", usagesLeft ) ]) ]

                          else
                            text ""
                        ]
                    , div [ class "sm:self-end" ]
                        [ div [ class "mt-3 flex flex-row items-center" ]
                            (if validationType == "CLAIMABLE" then
                                validatorAvatars

                             else
                                [ span [ class "text-date-purple uppercase text-sm mr-1" ]
                                    [ text_ "community.actions.automatic_analyzers" ]
                                , img [ src "/icons/tooltip.svg" ] []
                                ]
                            )
                        , div [ class "capitalize text-text-grey text-sm sm:text-right" ]
                            [ text_ "community.actions.verifiers" ]
                        ]
                    ]
                , div [ class "mt-5 flex flex-row items-baseline" ]
                    [ div [ class ("text-reward-green text-base mt-5 flex-grow-1" ++ rewardStrike) ]
                        [ span [] [ text (t "community.actions.reward" ++ ": ") ]
                        , span [ class "font-medium" ] [ text rewardStr ]
                        ]
                    , div [ class "hidden sm:flex sm:visible flex-row justify-end flex-grow-1" ]
                        [ if validationType == "CLAIMABLE" then
                            button
                                [ class ("h-10 uppercase rounded-lg ml-1" ++ claimColors ++ claimSize)
                                , onClick (OpenClaimConfirmation action.id)
                                ]
                                [ text_ claimText ]

                          else
                            text ""
                        ]
                    ]
                ]
            , div [ class "flex flex-row mt-8 justify-between sm:hidden" ]
                [ if validationType == "CLAIMABLE" then
                    button
                        [ class ("h-10 uppercase rounded-lg ml-1" ++ claimColors ++ claimSize)
                        , onClick (OpenClaimConfirmation action.id)
                        ]
                        [ text_ claimText ]

                  else
                    text ""
                ]
            ]


viewHeader : LoggedIn.Model -> Community -> Html Msg
viewHeader { shared } community =
    div []
        [ div [ class "h-16 w-full bg-indigo-500 flex px-4 items-center" ]
            [ a
                [ class "items-center flex absolute"
                , Route.href Route.Communities
                ]
                [ Icons.back ""
                , p [ class "text-white text-sm ml-2" ]
                    [ text (t shared.translations "back")
                    ]
                ]
            , p [ class "text-white mx-auto" ] [ text community.title ]
            ]
        , div [ class "h-24 lg:h-56 bg-indigo-500 flex flex-wrap content-end" ]
            [ div [ class "h-24 w-24 rounded-full mx-auto pt-12" ]
                [ img
                    [ src (shared.endpoints.ipfs ++ "/" ++ community.logo)
                    , class "object-scale-down"
                    ]
                    []
                ]
            ]
        ]


viewMessageStatus : LoggedIn.Model -> Model -> Html msg
viewMessageStatus loggedIn model =
    let
        t s =
            I18Next.t loggedIn.shared.translations s

        text_ s =
            text (t s)
    in
    case model.messageStatus of
        None ->
            text ""

        Success message ->
            div [ class "z-40 bg-green w-full my-2 p-2 rounded-lg text-center" ]
                [ p [ class "text-white font-sans" ] [ text_ message ]
                ]

        Failure message ->
            div [ class "z-40 bg-red w-full my-2 rounded-lg p-2 text-center" ]
                [ p [ class "text-white font-sans font-bold" ] [ text_ message ]
                ]


viewClaimModal : LoggedIn.Model -> Model -> Html Msg
viewClaimModal loggedIn model =
    case model.modalStatus of
        Opened isLoading actionId ->
            let
                t s =
                    I18Next.t loggedIn.shared.translations s

                text_ s =
                    text (t s)
            in
            div [ class "modal container" ]
                [ div [ class "modal-bg", onClick CloseClaimConfirmation ] []
                , div [ class "modal-content" ]
                    [ div [ class "w-full" ]
                        [ p [ class "w-full font-bold text-heading text-2xl mb-4" ]
                            [ text_ "community.claimAction.title" ]
                        , button
                            [ if not isLoading then
                                onClick CloseClaimConfirmation

                              else
                                onClick NoOp
                            , disabled isLoading
                            ]
                            [ Icons.close "absolute fill-current text-gray-400 top-0 right-0 mx-8 my-4"
                            ]
                        , p [ class "text-body w-full font-sans mb-10" ]
                            [ text_ "community.claimAction.body" ]
                        ]
                    , div [ class "w-full md:bg-gray-100 md:flex md:absolute rounded-b-lg md:inset-x-0 md:bottom-0 md:p-4 justify-center" ]
                        [ div [ class "flex" ]
                            [ button
                                [ class "flex-1 block button button-secondary mb-4 button-lg w-full md:w-40 md:mb-0"
                                , if not isLoading then
                                    onClick CloseClaimConfirmation

                                  else
                                    onClick NoOp
                                , disabled isLoading
                                ]
                                [ text_ "community.claimAction.no" ]
                            , div [ class "w-8" ] []
                            , button
                                [ class "flex-1 block button button-primary button-lg w-full md:w-40"
                                , if not isLoading then
                                    onClick (ClaimAction actionId)

                                  else
                                    onClick NoOp
                                , disabled isLoading
                                ]
                                [ text_ "community.claimAction.yes" ]
                            ]
                        ]
                    ]
                ]

        Closed ->
            text ""



-- SECTIONS


viewSections : LoggedIn.Model -> Model -> List Transfer -> Html Msg
viewSections loggedIn model allTransfers =
    let
        t s =
            I18Next.t loggedIn.shared.translations s

        toView verifications =
            List.map
                (viewVerification loggedIn.shared)
                verifications
    in
    Page.viewMaxTwoColumn
        [ Page.viewTitle (t "community.actions.last_title")
        , case model.actions of
            Nothing ->
                Page.viewCardEmpty [ text (t "community.actions.no_actions_yet") ]

            Just resp ->
                div []
                    [ if List.isEmpty resp.claims then
                        div [ class "mt-5" ]
                            [ Page.viewCardEmpty
                                [ text (t "community.actions.no_actions_yet") ]
                            ]

                      else
                        div
                            [ class "rounded-lg bg-white mt-5" ]
                            (toView (Community.toVerifications resp))
                    ]
        ]
        [ Page.viewTitle (t "transfer.last_title")
        , case allTransfers of
            [] ->
                div [ class "mt-5" ]
                    [ Page.viewCardEmpty [ text (t "transfer.no_transfers_yet") ]
                    ]

            transfers ->
                div [ class "rounded-lg bg-white mt-5" ]
                    (List.map
                        (\transfer ->
                            viewTransfer loggedIn model transfer
                        )
                        transfers
                    )
        ]


viewTransfer : LoggedIn.Model -> Model -> Transfer -> Html msg
viewTransfer loggedIn model transfer =
    let
        transferInfo from value to =
            let
                val =
                    String.fromFloat value
            in
            [ ( "from", Eos.nameToString from )
            , ( "value", val )
            , ( "to", Eos.nameToString to )
            ]
                |> I18Next.tr loggedIn.shared.translations I18Next.Curly "transfer.info"
    in
    a
        [ class "border-b last:border-b-0 border-gray-500 flex flex-wrap items-start p-4"
        , Route.href (Route.ViewTransfer transfer.id)
        ]
        [ div [ class "flex justify-between w-full" ]
            [ p [] [ text (transferInfo transfer.from.account transfer.value transfer.to.account) ]
            , p [ class "text-sm text-orange-500" ]
                (Page.viewDateDistance
                    (Utils.posixDateTime (Just transfer.blockTime))
                    model.date
                )
            ]
        , div [ class "w-full" ]
            [ case transfer.memo of
                Nothing ->
                    text ""

                Just mem ->
                    p [ class "flex-1 text-xs text-gray-700" ]
                        [ text mem ]
            ]
        ]



-- UPDATE


type alias UpdateResult =
    UR.UpdateResult Model Msg (External Msg)


type Msg
    = NoOp
    | GotTime Posix
    | CompletedLoadCommunity (Result (Graphql.Http.Error (Maybe Community)) (Maybe Community))
      -- Objective
    | ClickedOpenObjective Int
    | ClickedCloseObjective
      -- Action
    | OpenClaimConfirmation Int
    | CloseClaimConfirmation
    | ClaimAction Int
    | GotClaimActionResponse (Result Value String)
    | CompletedLoadActions (Result (Graphql.Http.Error ActionVerificationsResponse) ActionVerificationsResponse)


update : Msg -> Model -> LoggedIn.Model -> UpdateResult
update msg model loggedIn =
    case msg of
        NoOp ->
            UR.init model

        GotTime date ->
            UR.init { model | date = Just date }

        CompletedLoadCommunity (Ok community) ->
            case community of
                Just c ->
                    UR.init { model | community = Loaded c NoEdit }

                Nothing ->
                    UR.init { model | community = NotFound }

        CompletedLoadCommunity (Err err) ->
            { model | community = Failed err }
                |> UR.init
                |> UR.logGraphqlError msg err

        CompletedLoadActions (Ok resp) ->
            { model | actions = Just resp }
                |> UR.init

        CompletedLoadActions (Err err) ->
            model
                |> UR.init
                |> UR.logGraphqlError msg err

        ClickedOpenObjective index ->
            { model | openObjective = Just index }
                |> UR.init

        ClickedCloseObjective ->
            { model | openObjective = Nothing }
                |> UR.init

        OpenClaimConfirmation actionId ->
            { model | modalStatus = Opened False actionId }
                |> UR.init

        CloseClaimConfirmation ->
            { model | modalStatus = Closed }
                |> UR.init

        ClaimAction actionId ->
            let
                newModel =
                    { model | modalStatus = Opened True actionId }
            in
            if LoggedIn.isAuth loggedIn then
                newModel
                    |> UR.init
                    |> UR.addPort
                        { responseAddress = ClaimAction actionId
                        , responseData = Encode.null
                        , data =
                            Eos.encodeTransaction
                                { actions =
                                    [ { accountName = "bes.cmm"
                                      , name = "claimaction"
                                      , authorization =
                                            { actor = loggedIn.accountName
                                            , permissionName = Eos.samplePermission
                                            }
                                      , data =
                                            { actionId = actionId
                                            , maker = loggedIn.accountName
                                            }
                                                |> Community.encodeClaimAction
                                      }
                                    ]
                                }
                        }

            else
                newModel
                    |> UR.init
                    |> UR.addExt (Just (ClaimAction actionId) |> RequiredAuthentication)

        GotClaimActionResponse (Ok _) ->
            { model
                | modalStatus = Closed
                , messageStatus = Success "community.claimAction.success"
            }
                |> UR.init

        GotClaimActionResponse (Err _) ->
            { model
                | modalStatus = Closed
                , messageStatus = Failure "community.claimAction.failure"
            }
                |> UR.init


jsAddressToMsg : List String -> Value -> Maybe Msg
jsAddressToMsg addr val =
    case addr of
        "ClaimAction" :: [] ->
            Decode.decodeValue
                (Decode.oneOf
                    [ Decode.field "transactionId" Decode.string |> Decode.map Ok
                    , Decode.succeed (Err val)
                    ]
                )
                val
                |> Result.map (Just << GotClaimActionResponse)
                |> Result.withDefault Nothing

        _ ->
            Nothing


msgToString : Msg -> List String
msgToString msg =
    case msg of
        NoOp ->
            [ "NoOp" ]

        GotTime _ ->
            [ "GotTime" ]

        CompletedLoadCommunity r ->
            [ "CompletedLoadCommunity", UR.resultToString r ]

        ClickedOpenObjective _ ->
            [ "ClickedOpenObjective" ]

        ClickedCloseObjective ->
            [ "ClickedCloseObjective" ]

        OpenClaimConfirmation _ ->
            [ "OpenClaimConfirmation" ]

        CloseClaimConfirmation ->
            [ "CloseClaimConfirmation" ]

        ClaimAction _ ->
            [ "ClaimAction" ]

        GotClaimActionResponse r ->
            [ "GotClaimActionResponse", UR.resultToString r ]

        CompletedLoadActions _ ->
            [ "CompletedLoadActions" ]
