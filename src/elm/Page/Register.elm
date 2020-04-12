module Page.Register exposing (Model, Msg, init, jsAddressToMsg, msgToString, subscriptions, update, view)

import Api
import Auth exposing (viewFieldLabel)
import Browser.Dom as Dom
import Browser.Events
import Char
import Eos.Account as Eos
import Graphql.Http
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (keyCode, on, onClick, onInput, onSubmit)
import Http
import I18Next exposing (t)
import Json.Decode as Decode exposing (Decoder, Value)
import Json.Decode.Pipeline as Decode
import Json.Encode as Encode
import List.Extra as LE
import Profile exposing (Profile)
import Route
import Session.Guest as Guest exposing (External(..))
import Session.Shared exposing (Shared)
import Task
import UpdateResult as UR
import Utils exposing (..)
import Validate exposing (Validator, ifBlank, ifFalse, ifInvalidEmail, ifTrue, validate)



-- INIT


init : Guest.Model -> ( Model, Cmd Msg )
init guest =
    ( initModel guest
    , Cmd.none
    )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.map PressedEnter (Browser.Events.onKeyDown decodeEnterKeyDown)



-- MODEL


type alias Model =
    { accountKeys : Maybe AccountKeys
    , isLoading : Bool
    , isCheckingAccount : Bool
    , form : Form
    , accountGenerated : Bool
    , problems : List Problem
    }


initModel : Guest.Model -> Model
initModel _ =
    { accountKeys = Nothing
    , isLoading = False
    , isCheckingAccount = False
    , form = initForm
    , accountGenerated = False
    , problems = []
    }



---- FORM


type alias Form =
    { username : String
    , email : String
    , account : String
    , enteredPin : List (Maybe String)
    , enteredPinConf : List (Maybe String)
    }


initForm : Form
initForm =
    { username = ""
    , email = ""
    , account = ""
    , enteredPin = List.repeat 6 Nothing
    , enteredPinConf = List.repeat 6 Nothing
    }


type PinInput
    = PinInput
    | PinConfInput


type Problem
    = InvalidEntry ValidatedField String
    | ServerError String


type ValidatedField
    = Username
    | Email
    | Account
    | Pin
    | PinConfirmation


type ValidationError
    = AccountTooShort
    | AccountTooLong
    | AccountAlreadyExists
    | AccountInvalidChars
    | PinTooShort
    | PinTooLong
    | PinInvalidChars
    | PinConfirmDontMatch



---- ACCOUNT KEYS


type alias AccountKeys =
    { ownerKey : String
    , activeKey : String
    , accountName : Eos.Name
    , transactionId : String
    , words : String
    , privateKey : String
    }


decodeAccount : Decoder AccountKeys
decodeAccount =
    Decode.succeed AccountKeys
        |> Decode.required "ownerKey" Decode.string
        |> Decode.required "activeKey" Decode.string
        |> Decode.required "accountName" Eos.nameDecoder
        |> Decode.required "transactionId" Decode.string
        |> Decode.required "words" Decode.string
        |> Decode.required "privateKey" Decode.string



-- VIEW


view : Guest.Model -> Model -> Html Msg
view guest model =
    let
        shared =
            guest.shared

        t str =
            I18Next.t guest.shared.translations str

        text_ s =
            text (t s)

        isDisabled =
            model.isLoading || model.isCheckingAccount

        tr r_id replaces =
            I18Next.tr shared.translations I18Next.Curly r_id replaces

        name =
            accName model
    in
    if model.accountGenerated then
        div [ class "main__register__details" ]
            [ div [ class "register__congrats" ]
                [ div [ class "register__woman" ] []
                , p [ class "congrats__message" ]
                    [ span [] [ text_ "register.account_created.congrats" ]
                    , span [] [ text_ "register.account_created.account" ]
                    , span [] [ text_ "register.account_created.created" ]
                    ]
                , div [ class "register__dog" ] []
                ]
            , div [ class "register__welcome" ]
                [ text (tr "register.account_created.welcome_message" [ ( "username", name ) ]) ]
            , div [ class "register__keys" ]
                [ p [ class "key__title" ] [ text_ "register.account_created.twelve_words" ]
                , p [ class "key", id "12__words" ] [ text (words model) ]
                , p [ class "key__title" ] [ text_ "register.account_created.private_key" ]
                , p [ class "key", id "p__key" ] [ text (privateKey model) ]
                ]
            , div [ class "register__instructions" ]
                [ p [] [ text_ "register.account_created.instructions" ] ]
            , button
                [ onClick DownloadPdf
                , class "btn btn__register"
                ]
                [ text_ "register.account_created.download" ]
            , div [ class "register__footer" ]
                [ span [] [ text_ "register.account_created.instructions" ] ]
            ]

    else
        Html.form
            [ onSubmit ValidateForm
            ]
            [ div [ class "card card--register" ]
                [ viewAuthTabs shared
                , p [ class "card__auth__register__prompt" ]
                    [ text_ "register.form.title" ]
                , viewServerErrors model.problems
                , viewField shared
                    (Field
                        "register.form.name"
                        isDisabled
                        "name"
                        Username
                    )
                    (identity EnteredUsername)
                    [ maxlength 255 ]
                    model.problems
                , viewField shared
                    (Field
                        "register.form.account"
                        isDisabled
                        "account"
                        Account
                    )
                    (identity EnteredAccount)
                    Eos.nameValidationAttrs
                    model.problems
                , viewField shared
                    (Field
                        "register.form.email"
                        isDisabled
                        "email"
                        Email
                    )
                    (identity EnteredEmail)
                    [ type_ "email" ]
                    model.problems
                , viewPinForm model shared PinInput
                , viewPinForm model shared PinConfInput
                , button
                    [ class "btn btn--primary btn--login"
                    , type_ "submit"
                    , disabled isDisabled
                    ]
                    [ if model.isCheckingAccount then
                        text_ "register.form.checkingAvailability"

                      else
                        text_ "register.form.button"
                    ]
                , a [ Route.href (Route.Login Nothing), class "card__auth__prompt" ]
                    [ span [] [ text_ "register.login" ]
                    , span [ class "card__auth__login__mode" ] [ text_ "register.authLink" ]
                    ]
                ]
            ]


viewAuthTabs : Shared -> Html msg
viewAuthTabs { translations } =
    div [ class "card__auth__tabs__register" ]
        [ div [ class "enabled" ] [ p [] [ text (t translations "register.registerTab") ] ]
        , div [ class "disabled" ]
            [ a [ Route.href (Route.Login Nothing) ]
                [ p [] [ text (t translations "register.loginTab") ] ]
            ]
        ]


viewServerErrors : List Problem -> Html msg
viewServerErrors problems =
    let
        errorList =
            problems
                |> List.filterMap
                    (\p ->
                        case p of
                            ServerError e ->
                                Just (li [ class "field__error" ] [ text e ])

                            _ ->
                                Nothing
                    )
    in
    ul [] errorList


viewPinForm : Model -> Shared -> PinInput -> Html Msg
viewPinForm model shared inputType =
    let
        inputs =
            List.range 0 5
                |> List.map (\pos -> digitInput pos inputType model)

        pinPrompt =
            case inputType of
                PinInput ->
                    "auth.pin"

                PinConfInput ->
                    "auth.pinConfirmation"

        errors =
            case inputType of
                PinInput ->
                    List.map (\err -> viewFieldProblem Pin err) model.problems

                PinConfInput ->
                    List.map (\err -> viewFieldProblem PinConfirmation err) model.problems
    in
    div [ class "card__auth__pin__section" ]
        [ viewFieldLabel shared pinPrompt "pin_input_0" Nothing
        , div [] inputs
        , ul [] errors
        ]


digitInput : Int -> PinInput -> Model -> Html Msg
digitInput position inputType { form } =
    let
        getVal pinField =
            Maybe.andThen
                identity
                (LE.getAt position pinField)

        val =
            case inputType of
                PinInput ->
                    case getVal form.enteredPin of
                        Nothing ->
                            ""

                        Just dig ->
                            dig

                PinConfInput ->
                    case getVal form.enteredPinConf of
                        Nothing ->
                            ""

                        Just dig ->
                            dig

        msg =
            case inputType of
                PinInput ->
                    EnteredPin position

                PinConfInput ->
                    EnteredPinConf position

        inputId =
            case inputType of
                PinInput ->
                    "pin_input_" ++ String.fromInt position

                PinConfInput ->
                    "pin_conf_input_" ++ String.fromInt position
    in
    input
        [ class "card__auth__pin__input"
        , id inputId
        , maxlength 1
        , value val
        , onInput msg
        , required True
        , autocomplete False
        , attribute "inputmode" "numeric"
        ]
        []


type alias Field =
    { translationSuffix : String
    , isDisabled : Bool
    , id_ : String
    , validation : ValidatedField
    }


viewField : Shared -> Field -> (String -> FormInputMsg) -> List (Attribute FormInputMsg) -> List Problem -> Html Msg
viewField ({ translations } as shared) { translationSuffix, isDisabled, id_, validation } msg extraAttrs problems =
    let
        errors =
            List.map (\err -> viewFieldProblem validation err) problems

        fProbs =
            List.filter
                (\p ->
                    case p of
                        InvalidEntry v _ ->
                            validation == v

                        _ ->
                            False
                )
                problems

        errorClass =
            case fProbs of
                [] ->
                    ""

                _ ->
                    " errored__field"
    in
    div [ class "form-field" ]
        [ viewFieldLabel shared translationSuffix id_ Nothing
        , input
            ([ id id_
             , onInput msg
             , class ("input auth__input" ++ errorClass)
             , disabled isDisabled
             , required True
             , placeholder (t translations (translationSuffix ++ ".placeholder"))
             ]
                ++ extraAttrs
            )
            []
            |> Html.map UpdateForm
        , ul [] errors
        ]


viewFieldProblem : ValidatedField -> Problem -> Html msg
viewFieldProblem field problem =
    case problem of
        ServerError _ ->
            text ""

        InvalidEntry f str ->
            if f == field then
                li [ class "field__error" ] [ text str ]

            else
                text ""


validationErrorToString : Shared -> ValidationError -> String
validationErrorToString shared error =
    let
        t s =
            I18Next.t shared.translations s

        tr str values =
            I18Next.tr shared.translations I18Next.Curly str values
    in
    case error of
        AccountTooShort ->
            tr "error.tooShort" [ ( "minLength", "12" ) ]

        AccountTooLong ->
            tr "error.tooLong" [ ( "maxLength", "12" ) ]

        AccountAlreadyExists ->
            t "error.alreadyTaken"

        AccountInvalidChars ->
            t "register.form.accountCharError"

        PinTooShort ->
            tr "error.tooShort" [ ( "minLength", "6" ) ]

        PinTooLong ->
            tr "error.tooLong" [ ( "maxLength", "6" ) ]

        PinInvalidChars ->
            t "register.form.pinCharError"

        PinConfirmDontMatch ->
            t "register.form.pinConfirmError"


accName : Model -> String
accName model =
    case model.accountKeys of
        Just keys ->
            Eos.nameToString keys.accountName

        Nothing ->
            ""


words : Model -> String
words model =
    case model.accountKeys of
        Just keys ->
            keys.words

        Nothing ->
            ""


privateKey : Model -> String
privateKey model =
    case model.accountKeys of
        Just keys ->
            keys.privateKey

        Nothing ->
            ""



-- UPDATE


type alias UpdateResult =
    UR.UpdateResult Model Msg External


type Msg
    = UpdateForm FormInputMsg
    | Ignored
    | ValidateForm
    | GotAccountAvailabilityResponse Bool
    | AccountGenerated (Result Decode.Error AccountKeys)
    | CompletedCreateProfile AccountKeys (Result Http.Error Profile)
    | CompletedLoadProfile AccountKeys (Result Http.Error Profile)
    | EnteredPin Int String
    | EnteredPinConf Int String
    | DownloadPdf
    | PdfDownloaded
    | PressedEnter Bool


update : Maybe String -> Msg -> Model -> Guest.Model -> UpdateResult
update maybeInvitation msg model guest =
    let
        shared =
            guest.shared
    in
    case msg of
        Ignored ->
            model
                |> UR.init

        UpdateForm subMsg ->
            updateForm subMsg shared model
                |> UR.init

        ValidateForm ->
            let
                pinStr =
                    asPinString model.form.enteredPin

                pinConfStr =
                    asPinString model.form.enteredPinConf

                pinConfErrors =
                    if pinStr == pinConfStr then
                        []

                    else
                        [ InvalidEntry PinConfirmation (validationErrorToString shared PinConfirmDontMatch) ]

                allProbs =
                    model.problems
                        |> List.filter
                            (\p ->
                                case p of
                                    InvalidEntry PinConfirmation _ ->
                                        False

                                    _ ->
                                        True
                            )
                        |> (++) pinConfErrors
            in
            case allProbs of
                [] ->
                    { model | isCheckingAccount = True }
                        |> UR.init
                        |> UR.addPort
                            { responseAddress = ValidateForm
                            , responseData = Encode.null
                            , data =
                                Encode.object
                                    [ ( "name", Encode.string "checkAccountAvailability" )
                                    , ( "accountName", Encode.string model.form.account )
                                    ]
                            }

                _ ->
                    { model | problems = allProbs }
                        |> UR.init

        GotAccountAvailabilityResponse isAvailable ->
            if isAvailable then
                UR.init
                    { model
                        | isLoading = True
                        , problems = []
                        , isCheckingAccount = False
                    }
                    |> UR.addPort
                        { responseAddress = GotAccountAvailabilityResponse False
                        , responseData = Encode.null
                        , data =
                            Encode.object
                                [ ( "name", Encode.string "generateAccount" )
                                , ( "invitationId"
                                  , case maybeInvitation of
                                        Nothing ->
                                            Encode.null

                                        Just invitationId ->
                                            Encode.string invitationId
                                  )
                                , ( "pin"
                                  , Encode.string
                                        (model.form.enteredPin
                                            |> List.map (Maybe.withDefault "")
                                            |> String.concat
                                            |> String.reverse
                                        )
                                  )
                                , ( "account", Encode.string model.form.account )
                                ]
                        }

            else
                let
                    fieldError =
                        validationErrorToString shared AccountAlreadyExists
                            |> InvalidEntry Account
                in
                UR.init
                    { model
                        | problems = fieldError :: model.problems
                        , isCheckingAccount = False
                    }

        AccountGenerated (Ok accountKeys) ->
            UR.init
                { model
                    | isLoading = True
                    , accountKeys = Just accountKeys
                    , form = initForm
                }
                |> UR.addCmd
                    (case maybeInvitation of
                        Nothing ->
                            Api.signUp guest.shared
                                { name = model.form.username
                                , email = model.form.email
                                , account = accountKeys.accountName
                                , invitationId = maybeInvitation
                                }
                                (CompletedCreateProfile accountKeys)

                        Just _ ->
                            Api.signUpWithInvitation guest.shared
                                { name = model.form.username
                                , email = model.form.email
                                , account = accountKeys.accountName
                                , invitationId = maybeInvitation
                                }
                                (CompletedCreateProfile accountKeys)
                    )

        AccountGenerated (Err v) ->
            UR.init
                { model
                    | isLoading = False
                    , problems = ServerError "The server acted in an unexpected way" :: model.problems
                }
                |> UR.logDecodeError msg v

        CompletedCreateProfile _ (Ok _) ->
            { model | accountGenerated = True }
                |> UR.init
                |> UR.addPort
                    { responseAddress = Ignored
                    , responseData = Encode.null
                    , data =
                        Encode.object
                            [ ( "name", Encode.string "hideFooter" ) ]
                    }

        CompletedCreateProfile _ (Err err) ->
            { model | problems = ServerError "Auth failed" :: model.problems }
                |> UR.init
                |> UR.logHttpError msg err

        CompletedLoadProfile _ (Ok profile) ->
            UR.init model
                |> UR.addCmd (Route.replaceUrl guest.shared.navKey Route.Dashboard)
                |> UR.addExt (UpdatedGuest { guest | profile = Just profile })

        CompletedLoadProfile _ (Err err) ->
            { model | problems = ServerError "Auth failed" :: model.problems }
                |> UR.init
                |> UR.logHttpError msg err

        EnteredPin pos data ->
            let
                otherProblems =
                    model.problems
                        |> List.filter
                            (\p ->
                                case p of
                                    InvalidEntry Pin _ ->
                                        False

                                    _ ->
                                        True
                            )

                currentForm =
                    model.form

                newPin =
                    if data == "" then
                        LE.setAt pos Nothing model.form.enteredPin

                    else
                        LE.setAt pos (Just data) model.form.enteredPin

                pinErrors =
                    if List.any (\a -> a == Nothing) newPin then
                        [ InvalidEntry Pin (validationErrorToString shared PinTooShort) ]

                    else
                        []

                nextFocusPosition : Int
                nextFocusPosition =
                    if data == "" then
                        pos - 1

                    else
                        pos + 1
            in
            { model
                | form = { currentForm | enteredPin = newPin }
                , problems = otherProblems ++ pinErrors
            }
                |> UR.init
                |> UR.addPort
                    { responseAddress = Ignored
                    , responseData = Encode.null
                    , data =
                        Encode.object
                            [ ( "pos", Encode.int pos )
                            , ( "data", Encode.string data )
                            , ( "isWithinif", Encode.bool True )
                            ]
                    }
                |> UR.addCmd
                    (Task.attempt (\_ -> Ignored) (Dom.focus ("pin_input_" ++ String.fromInt nextFocusPosition)))

        EnteredPinConf pos data ->
            let
                otherProblems =
                    model.problems
                        |> List.filter
                            (\p ->
                                case p of
                                    InvalidEntry PinConfirmation _ ->
                                        False

                                    _ ->
                                        True
                            )

                currentForm =
                    model.form

                newPin =
                    if data == "" then
                        LE.setAt pos Nothing model.form.enteredPinConf

                    else
                        LE.setAt pos (Just data) model.form.enteredPinConf

                pinConfProbs =
                    if List.any (\a -> a == Nothing) newPin then
                        [ InvalidEntry PinConfirmation (validationErrorToString shared PinTooShort) ]

                    else
                        []

                nextFocusPosition : Int
                nextFocusPosition =
                    if data == "" then
                        pos - 1

                    else
                        pos + 1
            in
            { model
                | form = { currentForm | enteredPinConf = newPin }
                , problems = pinConfProbs ++ otherProblems
            }
                |> UR.init
                |> UR.addPort
                    { responseAddress = Ignored
                    , responseData = Encode.null
                    , data =
                        Encode.object
                            [ ( "pos", Encode.int pos )
                            , ( "data", Encode.string data )
                            , ( "isWithinif", Encode.bool True )
                            ]
                    }
                |> UR.addCmd
                    (Task.attempt (\_ -> Ignored) (Dom.focus ("pin_conf_input_" ++ String.fromInt nextFocusPosition)))

        DownloadPdf ->
            model
                |> UR.init
                |> UR.addPort
                    { responseAddress = PdfDownloaded
                    , responseData = Encode.null
                    , data =
                        Encode.object
                            [ ( "name", Encode.string "printAuthPdf" ) ]
                    }

        PdfDownloaded ->
            case model.accountKeys of
                Nothing ->
                    model
                        |> UR.init

                Just keys ->
                    model
                        |> UR.init
                        |> UR.addCmd
                            (CompletedLoadProfile keys
                                |> Api.signIn guest.shared keys.accountName
                            )

        PressedEnter val ->
            if val then
                UR.init model
                    |> UR.addCmd
                        (Task.succeed ValidateForm
                            |> Task.perform identity
                        )

            else
                UR.init model



--
-- Model functions
--


type FormInputMsg
    = EnteredUsername String
    | EnteredEmail String
    | EnteredAccount String


updateForm : FormInputMsg -> Shared -> Model -> Model
updateForm msg shared ({ form } as model) =
    let
        vErrorString verror =
            validationErrorToString shared verror

        fieldProbs validator val =
            case validate validator val of
                Ok _ ->
                    []

                Err errs ->
                    errs

        otherProbs validationField probs =
            probs
                |> List.filter
                    (\p ->
                        case p of
                            InvalidEntry v _ ->
                                v /= validationField

                            _ ->
                                True
                    )
    in
    case msg of
        EnteredUsername str ->
            let
                newProblems =
                    otherProbs Username model.problems

                nameValidator : Validator Problem String
                nameValidator =
                    Validate.firstError
                        [ ifBlank identity (InvalidEntry Username "Name can't be blank") ]

                nameProbs =
                    fieldProbs nameValidator str

                newForm =
                    { form | username = str }
            in
            { model
                | form = newForm
                , problems = newProblems ++ nameProbs
            }

        EnteredEmail str ->
            let
                newProblems =
                    otherProbs Email model.problems

                emailValidator : Validator Problem String
                emailValidator =
                    Validate.firstError
                        [ ifBlank identity (InvalidEntry Email "Email can't be blank")
                        , ifInvalidEmail identity (\_ -> InvalidEntry Email "Email has to be valid email")
                        ]

                emailProbs =
                    fieldProbs emailValidator str

                newForm =
                    { form | email = str }
            in
            { model
                | form = newForm
                , problems = newProblems ++ emailProbs
            }

        EnteredAccount str ->
            let
                newProblems =
                    otherProbs Account model.problems

                isLowerThan6 : Char -> Bool
                isLowerThan6 c =
                    let
                        charInt : Int
                        charInt =
                            c
                                |> String.fromChar
                                |> String.toInt
                                |> Maybe.withDefault 0
                    in
                    compare charInt 6 == Basics.LT

                isValidAlphaNum : Char -> Bool
                isValidAlphaNum c =
                    (Char.isUpper c || Char.isLower c || Char.isDigit c) && isLowerThan6 c

                accountValidator : Validator Problem String
                accountValidator =
                    Validate.firstError
                        [ ifBlank identity (InvalidEntry Account "Account is required")
                        , ifTrue (\accStr -> String.length accStr < 12) (InvalidEntry Account (vErrorString AccountTooShort))
                        , ifTrue (\accStr -> String.length accStr > 12) (InvalidEntry Account (vErrorString AccountTooLong))
                        , ifFalse (\accStr -> String.all isValidAlphaNum accStr) (InvalidEntry Account (vErrorString AccountInvalidChars))
                        ]

                accProbs =
                    fieldProbs accountValidator str

                newForm =
                    { form | account = str |> String.toLower }
            in
            { model
                | form = newForm
                , problems = newProblems ++ accProbs
            }


asPinString : List (Maybe String) -> String
asPinString entered =
    entered
        |> List.map (\a -> Maybe.withDefault "" a)
        |> List.foldl (\a b -> a ++ b) ""


jsAddressToMsg : List String -> Value -> Maybe Msg
jsAddressToMsg addr val =
    case addr of
        "ValidateForm" :: [] ->
            Decode.decodeValue
                (Decode.field "isAvailable" Decode.bool)
                val
                |> Result.map GotAccountAvailabilityResponse
                |> Result.toMaybe

        "GotAccountAvailabilityResponse" :: _ ->
            Decode.decodeValue (Decode.field "data" decodeAccount) val
                |> AccountGenerated
                |> Just

        "PdfDownloaded" :: _ ->
            Just PdfDownloaded

        _ ->
            Nothing


msgToString : Msg -> List String
msgToString msg =
    case msg of
        Ignored ->
            [ "Ignored" ]

        UpdateForm _ ->
            [ "UpdateForm" ]

        ValidateForm ->
            [ "ValidateForm" ]

        GotAccountAvailabilityResponse _ ->
            [ "GotAccountAvailabilityResponse" ]

        AccountGenerated r ->
            [ "AccountGenerated", UR.resultToString r ]

        CompletedCreateProfile _ r ->
            [ "CompletedCreateProfile", UR.resultToString r ]

        CompletedLoadProfile _ r ->
            [ "CompletedLoadProfile", UR.resultToString r ]

        EnteredPin _ _ ->
            [ "EnteredPin" ]

        EnteredPinConf _ _ ->
            [ "EnteredPinConf" ]

        DownloadPdf ->
            [ "DownloadPdf" ]

        PdfDownloaded ->
            [ "PdfDownloaded" ]

        PressedEnter _ ->
            [ "PressedEnter" ]
