class OLTogetherHUD extends OLHUD;

var array<string> ChatLines;
var array<string> Notifications;
var array<float> NotificationTimes;

var int ChatScrollIndex;
var float ChatScrollVisual;
var int MaxChatHistory;

var float UIScale;

var float LastChatInteractionTime;
var float ChatVisibilityAlpha;
var float ChatPanelOpenAnim;
var float LastChatLineTime;
var float ChatIdleFadeDelay;
var float ChatFadeDuration;

var int MouseX, MouseY;

var float NameFadeStartDist;
var float NameFadeEndDist;
var float NameNearFadeStart;
var float NameNearFadeEnd;

var string ModVersion;

// --- In-game settings menu ---
var bool  bSettingsOpen;
var float SettingsOpenAnim;        // 0 = closed, 1 = fully open
var float SettingsOpenTarget;      // where SettingsOpenAnim is heading
var int   SettingsOpenAnimVariant; // which of the entrance/exit styles is playing
var int   SettingsHighlightedRow;    // highlighted row
var bool  bRebindListening;    // waiting for a key press to bind
var int   RebindSlotIndex;  // which rebind row (0-3) is being rebound
var int   HoveredSettingsRow;      // row the mouse is hovering (-1=none, -2=back, 0+=rows, 100+=rebind)
var float SettingsTabAnim;     // eases on tab switch
var float SettingsTabTarget;   // where SettingsTabAnim is heading
var int   SettingsTabTransitionVariant; // which style for tab transition
var int   SettingsTab;         // active tab: 0=General 1=Voice 2=Keybinds 3=Models
var int   HoveredSettingsTab;  // tab header the mouse is over (-1=none)
var int   ModelScroll;         // first visible row in the Models list

// --- Speedrun HUD ---
var float SpeedrunTimerAlpha;
var float SpeedrunTimer;
var float SpeedrunAnimFlash;

const REF_HEIGHT = 720.0;
const NUM_SETTINGS_ANIMS = 16;
const NUM_CHAT_ANIMS = 8;
const NUM_MODEL_ROWS = 11;
const MODEL_VISIBLE_ROWS = 8;

// Chat animations states
var int ChatAnimVariant;

// --- Emoji picker ---
var OLTogetherEmoji EmojiData;
var array<string> EmojiCacheCodes;
var array<Texture2D> EmojiCacheTex;

var bool  bEmojiPickerOpen;
var float EmojiPickerAnim;      // 0 = closed, 1 = fully open
var float EmojiPickerTarget;    // where EmojiPickerAnim is heading
var int   EmojiPickerVariant;   // entrance/exit style
var int   EmojiCategory;        // active category tab
var float EmojiScroll;          // scroll offset in rows

// Hit-test results computed during draw, consumed by click handler
var bool  bHoverEmojiButton;
var int   HoveredEmojiTab;
var int   HoveredEmojiIndex;    // absolute index into EmojiData.Codes, -1 = none

// Emoji button rectangle (for the cursor hit-test), refreshed each chat draw
var float EmojiBtnX, EmojiBtnY, EmojiBtnS;

// Input-line geometry captured each draw so the click handler can map the
// mouse X position to a caret index in the chat text.
var float ChatInputX, ChatInputY, ChatInputW, ChatInputH;
var float ChatInputScroll;      // horizontal pixel scroll of the input text
var bool  bChatSelectingDrag;   // mouse button held and dragging a selection
var float LastCaretMoveTime;    // resets the caret blink so it stays solid while editing

const EMOJI_CACHE_MAX = 320;
const NUM_EMOJI_ANIMS = 6;

var Font CachedRobotoFont;
var Texture2D CachedCursorTex;

function Font GetRobotoFont()
{
    if (CachedRobotoFont == None)
    {
        CachedRobotoFont = Font(DynamicLoadObject("multiplayerassets.Fonts.RobotoSemiBold", class'Font', true));
        if (CachedRobotoFont == None)
            CachedRobotoFont = class'Engine'.Static.GetLargeFont();
    }
    return CachedRobotoFont;
}

event PostBeginPlay()
{
    super.PostBeginPlay();
    GetRobotoFont(); // Preload the font instantly on boot
}

function EnsureEmojiData()
{
    if (EmojiData == None)
        EmojiData = new(self) class'OLTogetherEmoji';
}

// On-demand texture loader with a small LRU-ish cache so the picker grid and
// inline chat emoji don't re-resolve the same package objects every frame.
function Texture2D GetEmojiTex(string Code)
{
    local int I;
    local Texture2D T;

    for (I = 0; I < EmojiCacheCodes.Length; I++)
        if (EmojiCacheCodes[I] == Code)
            return EmojiCacheTex[I];

    T = Texture2D(DynamicLoadObject("multiplayerassets.Emojis." $ Code, class'Texture2D', true));

    if (EmojiCacheCodes.Length >= EMOJI_CACHE_MAX)
    {
        EmojiCacheCodes.Remove(0, 1);
        EmojiCacheTex.Remove(0, 1);
    }
    EmojiCacheCodes.AddItem(Code);
    EmojiCacheTex.AddItem(T);
    return T;
}

function DrawEmojiTile(Texture2D T, float X, float Y, float S, float Alpha)
{
    local LinearColor LC;
    if (T == None)
        return;
    LC.R = 1.0;
    LC.G = 1.0;
    LC.B = 1.0;
    LC.A = Alpha;
    Canvas.SetPos(X, Y);
    Canvas.DrawTile(T, S, S, 0.0, 0.0, 64.0, 64.0, LC);
}

// Measures a chat string treating each {e:CODE} token as a square emoji of
// width EmojiSize and everything else as normal text.
function float MeasureRichW(string Text, float FontScale, float EmojiSize)
{
    local int I, N, CloseAt;
    local float W;
    local string Rest;

    I = 0;
    N = Len(Text);
    W = 0.0;
    while (I < N)
    {
        if (Mid(Text, I, 3) == "{e:")
        {
            Rest = Mid(Text, I);
            CloseAt = InStr(Rest, "}");
            if (CloseAt != -1)
            {
                W += EmojiSize;
                I += CloseAt + 1;
                continue;
            }
        }
        W += MeasureW(Mid(Text, I, 1), FontScale);
        I += 1;
    }
    return W;
}

function NoPause()
{
    if (PlayerOwner != None)
        OLPlayerController(PlayerOwner).ForcePause(false);
}

// Draws a chat string, rendering {e:CODE} tokens as inline emoji tiles and the
// rest as normal text. Returns nothing; used by the chat log and input line.
function DrawRichLine(string Text, float X, float Y, float FontScale, float EmojiSize, byte R, byte G, byte B, byte A)
{
    local int I, N, CloseAt;
    local float CurX, EmojiY, TextH;
    local string Rest, Code, Buffer;

    I = 0;
    N = Len(Text);
    CurX = X;
    Buffer = "";
    TextH = MeasureH("Ag", FontScale);
    EmojiY = Y + (TextH - EmojiSize) * 0.5;
    if (EmojiY < Y - EmojiSize)
        EmojiY = Y;

    while (I < N)
    {
        if (Mid(Text, I, 3) == "{e:")
        {
            Rest = Mid(Text, I);
            CloseAt = InStr(Rest, "}");
            if (CloseAt != -1)
            {
                if (Buffer != "")
                {
                    DrawLabel(Buffer, CurX, Y, FontScale, R, G, B, A);
                    CurX += MeasureW(Buffer, FontScale);
                    Buffer = "";
                }
                Code = Mid(Rest, 3, CloseAt - 3);
                DrawEmojiTile(GetEmojiTex(Code), CurX, EmojiY, EmojiSize, float(A) / 255.0);
                CurX += EmojiSize;
                I += CloseAt + 1;
                continue;
            }
        }
        Buffer = Buffer $ Mid(Text, I, 1);
        I += 1;
    }
    if (Buffer != "")
        DrawLabel(Buffer, CurX, Y, FontScale, R, G, B, A);
}

// Word-wraps a chat string that may contain {e:CODE} tokens, appending the
// wrapped rich-text lines onto OutLines. Emoji tokens are atomic units.
function WrapRichLine(string Text, float MaxWidth, float FontScale, float EmojiSize, out array<string> OutLines)
{
    local array<string> Atoms;
    local string Cur, Rest, Tok, Ch, Word, Chunk;
    local int I, N, CloseAt, K;

    if (Text == "")
    {
        OutLines.AddItem("");
        return;
    }

    // Tokenize into atoms: emoji tokens, single spaces, and word runs.
    I = 0;
    N = Len(Text);
    Word = "";
    while (I < N)
    {
        if (Mid(Text, I, 3) == "{e:")
        {
            Rest = Mid(Text, I);
            CloseAt = InStr(Rest, "}");
            if (CloseAt != -1)
            {
                if (Word != "")
                {
                    Atoms.AddItem(Word);
                    Word = "";
                }
                Tok = Left(Rest, CloseAt + 1);
                Atoms.AddItem(Tok);
                I += CloseAt + 1;
                continue;
            }
        }
        Ch = Mid(Text, I, 1);
        if (Ch == " ")
        {
            if (Word != "")
            {
                Atoms.AddItem(Word);
                Word = "";
            }
            Atoms.AddItem(" ");
        }
        else
        {
            Word = Word $ Ch;
        }
        I += 1;
    }
    if (Word != "")
        Atoms.AddItem(Word);

    // Greedy line fill by measured rich width.
    Cur = "";
    for (I = 0; I < Atoms.Length; I++)
    {
        if (MeasureRichW(Cur $ Atoms[I], FontScale, EmojiSize) > MaxWidth && Cur != "")
        {
            OutLines.AddItem(Cur);
            Cur = "";
            if (Atoms[I] == " ")
                continue;
        }

        // A single text word wider than the line gets broken by characters.
        if (Atoms[I] != " " && Left(Atoms[I], 3) != "{e:"
            && MeasureRichW(Atoms[I], FontScale, EmojiSize) > MaxWidth)
        {
            Chunk = "";
            for (K = 0; K < Len(Atoms[I]); K++)
            {
                if (MeasureRichW(Cur $ Chunk $ Mid(Atoms[I], K, 1), FontScale, EmojiSize) > MaxWidth
                    && (Cur $ Chunk) != "")
                {
                    OutLines.AddItem(Cur $ Chunk);
                    Cur = "";
                    Chunk = "";
                }
                Chunk = Chunk $ Mid(Atoms[I], K, 1);
            }
            Cur = Cur $ Chunk;
            continue;
        }

        Cur = Cur $ Atoms[I];
    }
    if (Cur != "")
        OutLines.AddItem(Cur);
}

// Renders a rich line clamped to MaxWidth by dropping leading content so the
// tail (where the caret is) stays visible. Used for the chat input preview.
function DrawRichLineTail(string Text, float X, float Y, float MaxWidth, float FontScale, float EmojiSize, byte R, byte G, byte B, byte A)
{
    local string Visible, Rest;
    local int CloseAt, StartI, N;

    // Fast path: whole thing fits.
    if (MeasureRichW(Text, FontScale, EmojiSize) <= MaxWidth)
    {
        DrawRichLine(Text, X, Y, FontScale, EmojiSize, R, G, B, A);
        return;
    }

    // Drop atoms from the front until the remainder fits.
    StartI = 0;
    N = Len(Text);
    while (StartI < N)
    {
        Visible = Mid(Text, StartI);
        if (MeasureRichW(Visible, FontScale, EmojiSize) <= MaxWidth)
            break;
        if (Mid(Text, StartI, 3) == "{e:")
        {
            Rest = Mid(Text, StartI);
            CloseAt = InStr(Rest, "}");
            if (CloseAt != -1)
            {
                StartI += CloseAt + 1;
                continue;
            }
        }
        StartI += 1;
    }
    DrawRichLine(Mid(Text, StartI), X, Y, FontScale, EmojiSize, R, G, B, A);
}

function AddChatLine(string Msg)
{
    if (Msg == "")
        return;

    ChatLines.AddItem(Msg);
    while (ChatLines.Length > MaxChatHistory)
        ChatLines.Remove(0, 1);

    if (ChatScrollIndex > 0)
        ChatScrollIndex++;

    NoteChatActivity();
}

function AddNotification(string Msg)
{
    if (Msg == "")
        return;

    Notifications.AddItem(Msg);
    NotificationTimes.AddItem(WorldInfo.TimeSeconds);
    while (Notifications.Length > 6)
    {
        Notifications.Remove(0, 1);
        NotificationTimes.Remove(0, 1);
    }
}

function NoteChatActivity()
{
    LastChatInteractionTime = WorldInfo.TimeSeconds;
    // Pick a random chat animation variant on activity for variety
    ChatAnimVariant = Rand(NUM_CHAT_ANIMS);
}

function ScrollChat(int Delta)
{
    ChatScrollIndex += Delta;
    if (ChatScrollIndex < 0)
        ChatScrollIndex = 0;

    NoteChatActivity();
}

function ResetChatVisibility()
{
    LastChatInteractionTime = WorldInfo.TimeSeconds;
    ChatVisibilityAlpha = 1.0;
    ChatPanelOpenAnim = 1.0;
}

Event OnLostFocusPause(Bool bEnable)
{
    local OLTogetherController PC;
    PC = OLTogetherController(PlayerOwner);
    if (PC != None && PC.Settings != None && !PC.Settings.bPauseOnLossFocus)
        return;
    Super.OnLostFocusPause(bEnable);
}

function float ViewW()
{
    local float W;
    W = Canvas.SizeX;
    if (W <= 0.0)
        W = Canvas.ClipX;
    if (W <= 0.0)
        W = 1280.0;
    return W;
}

function float ViewH()
{
    local float H;
    H = Canvas.SizeY;
    if (H <= 0.0)
        H = Canvas.ClipY;
    if (H <= 0.0)
        H = 720.0;
    return H;
}

function DrawFilledBox(float X, float Y, float W, float H, byte R, byte G, byte B, byte A)
{
    Canvas.SetDrawColor(R, G, B, A);
    Canvas.SetPos(X, Y);
    Canvas.DrawRect(W, H);
}

function DrawPanel(float X, float Y, float W, float H, float GlobalAlpha)
{
    local float B;
    B = FMax(1.0, 2.0 * UIScale);

    DrawFilledBox(X - B, Y - B, W + B * 2.0, H + B * 2.0, 60, 62, 68, byte(150.0 * GlobalAlpha));
    DrawFilledBox(X, Y, W, H, 14, 15, 18, byte(220.0 * GlobalAlpha));
    DrawFilledBox(X, Y, W, FMax(2.0, 3.0 * UIScale), 90, 92, 100, byte(230.0 * GlobalAlpha));
}

function DrawLabel(string Text, float X, float Y, float FontScale, byte R, byte G, byte B, byte A)
{
    FontScale *= 0.5;
    Canvas.Font = GetRobotoFont();
    Canvas.SetDrawColor(0, 0, 0, Min(A, 200));
    Canvas.SetPos(X + FMax(1.0, UIScale), Y + FMax(1.0, UIScale));
    Canvas.DrawText(Text, false, FontScale, FontScale);

    Canvas.SetDrawColor(R, G, B, A);
    Canvas.SetPos(X, Y);
    Canvas.DrawText(Text, false, FontScale, FontScale);
}

function float MeasureW(string Text, float FontScale)
{
    local float W, H;
    FontScale *= 0.5;
    Canvas.TextSize(Text, W, H);
    return W * FontScale;
}

function float MeasureH(string Text, float FontScale)
{
    local float W, H;
    FontScale *= 0.5;
    Canvas.TextSize(Text, W, H);
    return H * FontScale;
}

function string TrimTextToWidth(string Text, float MaxWidth, float FontScale)
{
    local int I;
    local string Candidate;

    if (Text == "")
        return "";

    for (I = Len(Text); I > 0; I--)
    {
        Candidate = Left(Text, I);
        if (MeasureW(Candidate, FontScale) <= MaxWidth)
            return Candidate;
    }
    return "";
}

// Appends the word-wrapped lines of Text onto OutLines. Note: this
// *appends*, it does not clear OutLines, since callers accumulate wrapped
// output from multiple source lines into the same array.
function WrapLine(string Text, float MaxWidth, float FontScale, out array<string> OutLines)
{
    local array<string> Words;
    local string CurLine, TestLine, Word, Chunk;
    local int I;

    if (Text == "")
    {
        OutLines.AddItem("");
        return;
    }

    Words = SplitString(Text, " ", false);
    CurLine = "";
    for (I = 0; I < Words.Length; I++)
    {
        Word = Words[I];

        while (MeasureW(Word, FontScale) > MaxWidth && Len(Word) > 1)
        {
            Chunk = Word;
            while (Len(Chunk) > 1 && MeasureW(Chunk, FontScale) > MaxWidth)
                Chunk = Left(Chunk, Len(Chunk) - 1);

            if (CurLine != "")
            {
                OutLines.AddItem(CurLine);
                CurLine = "";
            }
            if (Chunk != "")
                OutLines.AddItem(Chunk);
            Word = Right(Word, Len(Word) - Len(Chunk));
        }

        TestLine = (CurLine == "") ? Word : (CurLine $ " " $ Word);
        if (MeasureW(TestLine, FontScale) > MaxWidth && CurLine != "")
        {
            OutLines.AddItem(CurLine);
            CurLine = Word;
        }
        else
        {
            CurLine = TestLine;
        }
    }

    if (CurLine != "")
        OutLines.AddItem(CurLine);
}

function DrawNotificationsPanel()
{
    local int I;
    local float Age, Alpha, Y, PillW, PillH, TextScale, Pad, X, TW, Slide;
    local string Msg;

    while (Notifications.Length > 0 && WorldInfo.TimeSeconds - NotificationTimes[0] > 5.0)
    {
        Notifications.Remove(0, 1);
        NotificationTimes.Remove(0, 1);
    }

    if (Notifications.Length == 0)
        return;

    TextScale = 0.80 * UIScale;
    Pad = 10.0 * UIScale;
    PillH = MeasureH("Ag", TextScale) + Pad;
    Y = 16.0 * UIScale;

    for (I = Notifications.Length - 1; I >= 0; I--)
    {
        Msg = Notifications[I];
        Age = WorldInfo.TimeSeconds - NotificationTimes[I];

        Alpha = 235.0;
        if (Age < 0.35)
            Alpha = 235.0 * (Age / 0.35);
        else if (Age > 4.0)
            Alpha = 235.0 - (Age - 4.0) * 235.0;
        if (Alpha <= 0.0)
            continue;

        Slide = 0.0;
        if (Age < 0.35)
            Slide = (1.0 - (Age / 0.35)) * 40.0 * UIScale;

        TW = MeasureW(Msg, TextScale);
        PillW = TW + Pad * 2.0;
        X = ViewW() - PillW - 16.0 * UIScale + Slide;

        DrawFilledBox(X, Y, PillW, PillH, 18, 19, 23, byte(Alpha * 0.9));
        DrawFilledBox(X, Y, FMax(2.0, 3.0 * UIScale), PillH, 150, 152, 160, byte(Alpha));
        DrawLabel(Msg, X + Pad, Y + Pad * 0.5, TextScale, 220, 222, 230, byte(Alpha));

        Y += PillH + 6.0 * UIScale;
    }
}

function DrawNameTag(OLTogetherController PC)
{
    local int I;
    local vector NameScreen, NameWorld, CamLoc;
    local rotator CamRot;
    local float NameXL, NameYL, NameX, NameY, TextScale, Pad;
    local float Dist, DistAlpha, NearAlpha, A;
    local float TagW, TagX, TagY, BarW, BarH, BarX, BarY, HealthPct;
    local float TalkBoxSize, TalkBoxX, TalkBoxY;
    local byte HR, HG, HB;
    local string NameText;

    TextScale = 0.85 * UIScale;
    Pad = 5.0 * UIScale;

    for (I = 0; I < PC.RemotePlayers.Length; I++)
    {
        if (PC.RemotePlayers[I].RemotePawn == None || PC.RemotePlayers[I].PlayerName == "")
            continue;

        NameText = PC.RemotePlayers[I].PlayerName;
        NameWorld = PC.RemotePlayers[I].RemotePawn.Location + vect(0.0, 0.0, 175.0);

        CamLoc = NameWorld;
        PC.GetPlayerViewPoint(CamLoc, CamRot);
        Dist = VSize(NameWorld - CamLoc);

        DistAlpha = 1.0;
        if (Dist > NameFadeStartDist)
            DistAlpha = 1.0 - (Dist - NameFadeStartDist) / (NameFadeEndDist - NameFadeStartDist);
        DistAlpha = FClamp(DistAlpha, 0.0, 1.0);

        NearAlpha = 1.0;
        if (Dist < NameNearFadeStart)
            NearAlpha = (Dist - NameNearFadeEnd) / (NameNearFadeStart - NameNearFadeEnd);
        NearAlpha = FClamp(NearAlpha, 0.0, 1.0);

        DistAlpha = FMin(DistAlpha, NearAlpha);
        if (DistAlpha <= 0.01)
            continue;

        NameScreen = Canvas.Project(NameWorld);
        if (NameScreen.Z <= 0.0)
            continue;

        A = 255.0 * DistAlpha;

        NameXL = MeasureW(NameText, TextScale);
        NameYL = MeasureH(NameText, TextScale);

        BarH = FMax(3.0, 5.0 * UIScale);
        TalkBoxSize = 10.0 * UIScale;
        TagW = FMax(NameXL + (PC.RemotePlayers[I].bTalking ? TalkBoxSize + 8.0 * UIScale : 0.0), 90.0 * UIScale);
        TagX = NameScreen.X - (TagW * 0.5);
        NameX = NameScreen.X - (NameXL * 0.5);
        NameY = NameScreen.Y - NameYL - BarH - 10.0 * UIScale;
        TagY = NameY - Pad * 0.5;

        DrawFilledBox(TagX - Pad, TagY, TagW + Pad * 2.0, NameYL + BarH + Pad * 2.0, 12, 13, 16, byte(190.0 * DistAlpha));
        DrawFilledBox(TagX - Pad, TagY, TagW + Pad * 2.0, FMax(1.0, 2.0 * UIScale), 120, 122, 130, byte(220.0 * DistAlpha));

        DrawLabel(NameText, NameX, NameY, TextScale, 230, 232, 240, byte(A));

        if (PC.RemotePlayers[I].bTalking)
        {
            TalkBoxX = NameX + NameXL + 8.0 * UIScale;
            TalkBoxY = NameY + FMax(0.0, (NameYL - TalkBoxSize) * 0.5);
            DrawFilledBox(TalkBoxX, TalkBoxY, TalkBoxSize, TalkBoxSize, 255, 255, 255, byte(A));
        }

        HealthPct = FClamp(float(PC.RemotePlayers[I].Health) / 100.0, 0.0, 1.0);
        BarW = TagW;
        BarX = TagX;
        BarY = NameY + NameYL + 3.0 * UIScale;

        DrawFilledBox(BarX, BarY, BarW, BarH, 30, 32, 36, byte(200.0 * DistAlpha));
        if (HealthPct > 0.0)
        {
            HR = byte((1.0 - HealthPct) * 200.0);
            HG = byte(60.0 + HealthPct * 175.0);
            HB = 60;
            DrawFilledBox(BarX, BarY, BarW * HealthPct, BarH, HR, HG, HB, byte(235.0 * DistAlpha));
        }
        DrawFilledBox(BarX, BarY, BarW, FMax(1.0, UIScale), 90, 92, 100, byte(120.0 * DistAlpha));
    }
}

function UpdateChatAnimation(OLTogetherController PC, float Delta)
{
    local float TargetVisible, IdleTime;
    local float ShowRate, HideRate, OpenRate;
    local bool bWantVisible;

    // Exponential smoothing rates. Higher = snappier. Fade-in stays quick and
    // responsive; fade-out is gentler so the panel eases away rather than popping.
    ShowRate = 14.0;
    HideRate = 6.0;
    OpenRate = 16.0;

    bWantVisible = false;
    if (PC.bChatMode)
        bWantVisible = true;
    else if (ChatScrollIndex > 0)
        bWantVisible = true;
    else
    {
        IdleTime = WorldInfo.TimeSeconds - LastChatInteractionTime;
        if (IdleTime < ChatIdleFadeDelay)
            bWantVisible = true;
    }

    TargetVisible = bWantVisible ? 1.0 : 0.0;

    // Frame-rate independent approach toward the target alpha.
    if (TargetVisible > ChatVisibilityAlpha)
        ChatVisibilityAlpha += (TargetVisible - ChatVisibilityAlpha) * FMin(1.0, Delta * ShowRate);
    else
        ChatVisibilityAlpha += (TargetVisible - ChatVisibilityAlpha) * FMin(1.0, Delta * HideRate);

    ChatVisibilityAlpha = FClamp(ChatVisibilityAlpha, 0.0, 1.0);

    // Input box open/close eases with the same smoothing for a consistent feel.
    ChatPanelOpenAnim += ((PC.bChatMode ? 1.0 : 0.0) - ChatPanelOpenAnim) * FMin(1.0, Delta * OpenRate);
    ChatPanelOpenAnim = FClamp(ChatPanelOpenAnim, 0.0, 1.0);

    // Smooth the visual scroll index toward the logical one.
    ChatScrollVisual += (float(ChatScrollIndex) - ChatScrollVisual) * FMin(1.0, Delta * 18.0);

    if (!PC.bChatMode && ChatVisibilityAlpha <= 0.01)
    {
        ChatScrollIndex = 0;
        ChatScrollVisual = 0.0;
    }
}

function DrawChatPanel(OLTogetherController PC)
{
    local array<string> Display;
    local float PanelX, PanelY, PanelW, PanelH, Pad, LineH, FontBody, FontSmall;
    local float CX, CY, ContentW, LogH, InputH;
    local float Margin;
    local float GA, EaseOpen, SlideY, OffX, OffY, Sc;
    local int I, VisibleLines, Total, StartRowIndex, MaxOffset, Drawn, LinesToDraw;
    local int TabI, CatStart, CatCount, RowI, ColI, PerRow, RowCount, BaseIdx, EndIdx;
    local float PickerX, PickerY, PickerW, PickerH, PickerPad, PickerHeaderH, PickerGridY, PickerGridH, PickerCell, PickerGap;
    local float PickerBodyX, PickerBodyY, PickerBodyW, PickerBodyH, PickerScrollH, PickerTabH, PickerBodyAlpha, PickScale, PickSlide;
    local float BtnSize, BtnX, BtnY, BtnAlpha, GridX, GridY, GridW, GridH, CellX, CellY, CellS, EmojiAlpha;
    local string InputText, ScrollHint, TabText;
    local Texture2D EmojiTex;
    local OLTogetherEmoji Ed;
    local bool bEmojiPickerVisible;
    local OLTogetherInput Input;
    local float CaretX, SelStartX, SelEndX, TextAreaW, FullTextW, HScroll;
    local int SelA, SelB, CaretIdx;
    local bool bCaretOn;
    local float LogScrollOffset;

    GA = ChatVisibilityAlpha;
    if (GA <= 0.01)
        return;

    if (PC.bChatMode)
    {
        Input = OLTogetherInput(PC.PlayerInput);
        if (Input != None)
        {
            MouseX = Input.MousePosition.X;
            MouseY = Input.MousePosition.Y;
        }
    }

    Margin = 16.0 * UIScale;
    Pad = 8.0 * UIScale;
    FontBody = 0.72 * UIScale;
    FontSmall = 0.68 * UIScale;
    LineH = MeasureH("Ag", FontBody) + 2.0 * UIScale;

    EaseOpen = ChatPanelOpenAnim * ChatPanelOpenAnim * (3.0 - 2.0 * ChatPanelOpenAnim);

    PanelW = FClamp(ViewW() * 0.24, 280.0 * UIScale, 420.0 * UIScale);
    if (PanelW > ViewW() - Margin * 2.0)
        PanelW = ViewW() - Margin * 2.0;
    if (PanelW < 200.0)
        PanelW = 200.0;

    ContentW = PanelW - Pad * 2.0;

    // Reserve the same strip height regardless of mode so the panel never
    // jumps when the player toggles chat on/off.
    InputH = LineH + Pad * 0.5;

    VisibleLines = int((ViewH() * 0.34) / LineH);
    if (VisibleLines < 6)
        VisibleLines = 6;
    if (VisibleLines > 16)
        VisibleLines = 16;

    Display.Length = 0;
    for (I = 0; I < ChatLines.Length; I++)
        WrapLine(ChatLines[I], ContentW, FontSmall, Display);

    Total = Display.Length;

    MaxOffset = Total - VisibleLines;
    if (MaxOffset < 0)
        MaxOffset = 0;
    if (ChatScrollIndex > MaxOffset)
        ChatScrollIndex = MaxOffset;

    // Compact height: only reserve space for lines that actually exist,
    // clamped to the visible-lines cap.  When the chat is idle and has
    // few messages the panel shrinks accordingly.
    LinesToDraw = Total - ChatScrollIndex;
    if (LinesToDraw < 0)
        LinesToDraw = 0;
    if (LinesToDraw > VisibleLines)
        LinesToDraw = VisibleLines;

    LogH = LinesToDraw * LineH;
    PanelH = Pad * 2.0 + LogH + InputH;

    // Apply chat animation offsets for varied entrance/exit effects
    GetChatAnimOffsets(OffX, OffY, Sc);
    SlideY = (1.0 - GA) * 24.0 * UIScale + OffY;

    PanelX = Margin + OffX;
    PanelY = ViewH() - PanelH - Margin + SlideY;
    if (PanelY < Margin)
        PanelY = Margin;

    DrawPanel(PanelX, PanelY, PanelW, PanelH, GA);

    CX = PanelX + Pad;
    CY = PanelY + Pad;

    // Clamp and snap visual scroll
    ChatScrollVisual = FClamp(ChatScrollVisual, 0.0, float(MaxOffset));

    // Draw lines with sub-line pixel offset for smooth scrolling.
    StartRowIndex = Total - LinesToDraw - ChatScrollIndex;
    if (StartRowIndex < 0)
        StartRowIndex = 0;

    Canvas.PushMaskRegion(CX, CY, ContentW, LogH + 2.0 * UIScale);
    LogScrollOffset = (ChatScrollVisual - float(ChatScrollIndex)) * LineH;
    Drawn = 0;
    for (I = StartRowIndex; I < Total && Drawn < LinesToDraw; I++)
    {
        DrawRichLine(Display[I], CX, CY - LogScrollOffset, FontSmall, LineH, 220, 222, 228, byte(255.0 * GA));
        CY += LineH;
        Drawn++;
    }
    Canvas.PopMaskRegion();

    if (Total > VisibleLines)
        DrawScrollbar(PanelX + PanelW - 5.0 * UIScale, PanelY + Pad, LogH, Total, VisibleLines, StartRowIndex, GA);

    DrawFilledBox(CX, CY + Pad * 0.2, ContentW, FMax(1.0, UIScale), 55, 57, 63, byte(160.0 * GA));
    CY += Pad * 0.5;

    // The emoji button sits at the far right of the input strip. Reserve room
    // for it so text never runs under it.
    BtnSize = LineH;
    BtnAlpha = GA * EaseOpen;

    if (PC.bChatMode)
    {
        DrawFilledBox(CX - 4.0 * UIScale, CY - 2.0 * UIScale, ContentW + 8.0 * UIScale, LineH + 4.0 * UIScale, 26, 28, 34, byte(210.0 * GA));

        TextAreaW = ContentW - BtnSize - 6.0 * UIScale;
        CaretIdx = PC.ChatCaretPos;
        if (CaretIdx > Len(PC.ChatText))
            CaretIdx = Len(PC.ChatText);

        FullTextW = MeasureW("> " $ PC.ChatText, FontBody);
        CaretX = MeasureW("> " $ Left(PC.ChatText, CaretIdx), FontBody);

        HScroll = ChatInputScroll;
        if (CaretX - HScroll > TextAreaW - 4.0 * UIScale)
            HScroll = CaretX - TextAreaW + 4.0 * UIScale;
        if (CaretX - HScroll < 0.0)
            HScroll = CaretX;
        if (HScroll < 0.0)
            HScroll = 0.0;
        ChatInputScroll = HScroll;

        ChatInputX = CX;
        ChatInputY = CY;
        ChatInputW = TextAreaW;
        ChatInputH = LineH;

        Canvas.PushMaskRegion(CX, CY - 2.0 * UIScale, TextAreaW, LineH + 4.0 * UIScale);

        SelA = ChatSelMinIdx(PC);
        SelB = ChatSelMaxIdx(PC);
        if (SelA != SelB)
        {
            SelStartX = CX + MeasureW("> " $ Left(PC.ChatText, SelA), FontBody) - HScroll;
            SelEndX = CX + MeasureW("> " $ Left(PC.ChatText, SelB), FontBody) - HScroll;
            DrawFilledBox(SelStartX, CY - 1.0 * UIScale, SelEndX - SelStartX, LineH + 2.0 * UIScale, 60, 100, 180, byte(140.0 * GA));
        }

        DrawLabel("> " $ PC.ChatText, CX - HScroll, CY, FontBody, 225, 227, 235, byte(255.0 * GA));

        bCaretOn = (int((WorldInfo.TimeSeconds - LastCaretMoveTime) * 2.0) % 2 == 0);
        if (bCaretOn)
        {
            DrawFilledBox(CX + CaretX - HScroll, CY, FMax(1.0, UIScale), LineH, 225, 227, 235, byte(255.0 * GA));
        }

        Canvas.PopMaskRegion();

        // Emoji button (uses the blank emoji texture as its face).
        EnsureEmojiData();
        BtnY = CY - 2.0 * UIScale;
        BtnSize = LineH + 4.0 * UIScale;
        BtnX = PanelX + PanelW - Pad - BtnSize;
        EmojiBtnX = BtnX;
        EmojiBtnY = BtnY;
        EmojiBtnS = BtnSize;

        bHoverEmojiButton = (MouseX >= BtnX && MouseX < BtnX + BtnSize
            && MouseY >= BtnY && MouseY < BtnY + BtnSize);

        DrawFilledBox(BtnX, BtnY, BtnSize, BtnSize,
            bHoverEmojiButton ? 60 : 40, bHoverEmojiButton ? 64 : 42, bHoverEmojiButton ? 74 : 50, byte(230.0 * GA));
        EmojiTex = GetEmojiTex(bEmojiPickerOpen ? "1f642" : "EmojiBlank");
        if (EmojiTex != None)
            DrawEmojiTile(EmojiTex, BtnX + (BtnSize - LineH) * 0.5, BtnY + (BtnSize - LineH) * 0.5, LineH, GA);
        else
            DrawLabel(":)", BtnX, CY, FontBody, 220, 222, 230, byte(255.0 * GA));
    }
    else
    {
        EmojiBtnS = 0.0;
        ScrollHint = "Press T to chat";
        if (Total > VisibleLines)
            ScrollHint = ScrollHint $ "   -   Scroll to view history";
        DrawLabel(ScrollHint, CX, CY, FontSmall, 120, 122, 130, byte(200.0 * GA));
    }

    // --- Emoji picker (Discord-style category grid), drawn above the input ---
    bEmojiPickerVisible = (EmojiPickerAnim > 0.01);
    HoveredEmojiTab = -1;
    HoveredEmojiIndex = -1;

    if (PC.bChatMode && bEmojiPickerVisible)
    {
        EnsureEmojiData();
        Ed = EmojiData;
        if (Ed == None)
            return;

        PickScale = EmojiPickerAnim * EmojiPickerAnim * (3.0 - 2.0 * EmojiPickerAnim);
        PickerBodyAlpha = GA * PickScale;

        PickerPad = 6.0 * UIScale;
        PickerCell = 26.0 * UIScale;
        PickerGap = 3.0 * UIScale;
        PickerTabH = 18.0 * UIScale;

        PickerW = PanelW;
        PerRow = int((PickerW - PickerPad * 2.0) / (PickerCell + PickerGap));
        if (PerRow < 4)
            PerRow = 4;

        PickerGridH = (PickerCell + PickerGap) * 6.0;
        PickerHeaderH = PickerTabH + PickerPad;
        PickerH = PickerHeaderH + PickerGridH + PickerPad * 2.0;

        // Entrance animation: rise from the input box and fade in.
        PickSlide = (1.0 - PickScale) * 30.0 * UIScale;
        PickerX = PanelX;
        PickerY = PanelY - PickerH - 6.0 * UIScale + PickSlide;
        if (PickerY < Margin)
            PickerY = Margin;

        DrawPanel(PickerX, PickerY, PickerW, PickerH, PickerBodyAlpha);

        // Category tabs across the top.
        DrawEmojiTabs(Ed, PickerX + PickerPad, PickerY + PickerPad,
            PickerW - PickerPad * 2.0, PickerTabH, PickerBodyAlpha);

        // Grid body.
        GridX = PickerX + PickerPad;
        GridY = PickerY + PickerHeaderH + PickerPad;
        GridW = PickerW - PickerPad * 2.0;
        GridH = PickerGridH;

        if (EmojiCategory < 0)
            EmojiCategory = 0;
        if (EmojiCategory >= Ed.CatNames.Length)
            EmojiCategory = Ed.CatNames.Length - 1;

        CatStart = Ed.CatStarts[EmojiCategory];
        CatCount = Ed.CatCounts[EmojiCategory];
        RowCount = (CatCount + PerRow - 1) / PerRow;

        // Clamp scroll to content.
        if (EmojiScroll < 0.0)
            EmojiScroll = 0.0;
        if (EmojiScroll > float(RowCount) - 6.0)
            EmojiScroll = FMax(0.0, float(RowCount) - 6.0);

        CellS = PickerCell;
        BaseIdx = int(EmojiScroll) * PerRow;
        EndIdx = BaseIdx + PerRow * 7;
        if (EndIdx > CatCount)
            EndIdx = CatCount;

        for (I = BaseIdx; I < EndIdx; I++)
        {
            RowI = (I / PerRow) - int(EmojiScroll);
            ColI = I % PerRow;
            CellX = GridX + ColI * (CellS + PickerGap);
            CellY = GridY + RowI * (CellS + PickerGap);
            if (CellY + CellS <= GridY || CellY >= GridY + GridH)
                continue;

            EmojiAlpha = PickerBodyAlpha;
            if (MouseX >= CellX && MouseX < CellX + CellS && MouseY >= CellY && MouseY < CellY + CellS
                && CellY >= GridY - CellS * 0.5 && CellY <= GridY + GridH)
            {
                HoveredEmojiIndex = CatStart + I;
                DrawFilledBox(CellX - 1.0 * UIScale, CellY - 1.0 * UIScale, CellS + 2.0 * UIScale, CellS + 2.0 * UIScale,
                    70, 120, 90, byte(160.0 * PickerBodyAlpha));
            }

            EmojiTex = GetEmojiTex(Ed.Codes[CatStart + I]);
            if (EmojiTex != None)
                DrawEmojiTile(EmojiTex, CellX, CellY, CellS, EmojiAlpha);
        }

        // Scrollbar for the grid.
        if (RowCount > 6)
            DrawScrollbar(PickerX + PickerW - 5.0 * UIScale, GridY, GridH, RowCount, 6, int(EmojiScroll), PickerBodyAlpha);

        // Draw the cursor on top of the picker while chatting with it open.
        DrawCursor(PickerBodyAlpha);
    }
    else if (PC.bChatMode)
    {
        DrawCursor(GA);
    }
}

// Draws the category tab strip and records the hovered tab for click handling.
function DrawEmojiTabs(OLTogetherEmoji Ed, float X, float Y, float W, float H, float Alpha)
{
    local int I, N;
    local float TabW, TX;
    local string Lbl;
    local byte BA;

    N = Ed.CatNames.Length;
    if (N <= 0)
        return;

    TabW = W / float(N);
    BA = byte(255.0 * Alpha);

    for (I = 0; I < N; I++)
    {
        TX = X + I * TabW;

        if (MouseX >= TX && MouseX < TX + TabW && MouseY >= Y && MouseY < Y + H)
        {
            HoveredEmojiTab = I;
            DrawFilledBox(TX, Y, TabW - 2.0 * UIScale, H, 70, 120, 90, byte(150.0 * Alpha));
        }
        else if (I == EmojiCategory)
        {
            DrawFilledBox(TX, Y, TabW - 2.0 * UIScale, H, 70, 90, 120, byte(150.0 * Alpha));
        }
        else
        {
            DrawFilledBox(TX, Y, TabW - 2.0 * UIScale, H, 30, 32, 38, byte(120.0 * Alpha));
        }

        Lbl = TrimTextToWidth(Ed.CatNames[I], TabW - 4.0 * UIScale, 0.55 * UIScale);
        DrawLabel(Lbl, TX + 3.0 * UIScale, Y + 2.0 * UIScale, 0.55 * UIScale, 220, 222, 230, BA);
    }
}

// Updates the picker open/close animation toward its target.
function UpdateEmojiPickerAnimation(float Delta)
{
    local float Rate;
    Rate = 14.0;
    EmojiPickerTarget = bEmojiPickerOpen ? 1.0 : 0.0;
    EmojiPickerAnim += (EmojiPickerTarget - EmojiPickerAnim) * FMin(1.0, Delta * Rate);
    EmojiPickerAnim = FClamp(EmojiPickerAnim, 0.0, 1.0);
}

function ToggleEmojiPicker()
{
    bEmojiPickerOpen = !bEmojiPickerOpen;
    if (bEmojiPickerOpen)
    {
        EnsureEmojiData();
        EmojiPickerVariant = Rand(NUM_EMOJI_ANIMS);
    }
    NoteChatActivity();
}

function CloseEmojiPicker()
{
    bEmojiPickerOpen = false;
    EmojiPickerTarget = 0.0;
}

function ScrollEmojiPicker(int Delta)
{
    EmojiScroll += float(Delta);
    if (EmojiScroll < 0.0)
        EmojiScroll = 0.0;
    NoteChatActivity();
}

// Routes a click while chatting. Returns true if the click was consumed by the
// emoji button, a category tab, or an emoji cell.
function bool EmojiPickerClick(OLTogetherController PC)
{
    // Emoji button toggles the picker.
    if (EmojiBtnS > 0.0 && MouseX >= EmojiBtnX - 2.0 * UIScale && MouseX < EmojiBtnX + EmojiBtnS + 2.0 * UIScale
        && MouseY >= EmojiBtnY - 1.0 * UIScale && MouseY < EmojiBtnY + EmojiBtnS + 2.0 * UIScale)
    {
        ToggleEmojiPicker();
        return true;
    }

    if (!bEmojiPickerOpen || EmojiPickerAnim <= 0.5)
        return false;

    if (HoveredEmojiTab >= 0)
    {
        EmojiCategory = HoveredEmojiTab;
        EmojiScroll = 0.0;
        NoteChatActivity();
        return true;
    }

    if (HoveredEmojiIndex >= 0 && EmojiData != None && HoveredEmojiIndex < EmojiData.Codes.Length)
    {
        InsertEmojiToken(PC, EmojiData.Codes[HoveredEmojiIndex]);
        return true;
    }

    return false;
}

function InsertEmojiToken(OLTogetherController PC, string Code)
{
    local string Token;
    Token = "{e:" $ Code $ "}";
    if (Len(PC.ChatText) + Len(Token) > 220)
        return;
    PC.ChatText = PC.ChatText $ Token;
    NoteChatActivity();
}

// True when the cursor is over the picker or the emoji button, so clicks there
// are handled by the picker rather than falling through.
function bool IsMouseOverEmojiUI()
{
    if (EmojiBtnS > 0.0 && MouseX >= EmojiBtnX - 2.0 * UIScale && MouseX < EmojiBtnX + EmojiBtnS + 2.0 * UIScale
        && MouseY >= EmojiBtnY - 1.0 * UIScale && MouseY < EmojiBtnY + EmojiBtnS + 2.0 * UIScale)
        return true;
    return bEmojiPickerOpen && (HoveredEmojiTab >= 0 || HoveredEmojiIndex >= 0);
}

function int ChatSelMinIdx(OLTogetherController PC)
{
    if (PC.ChatSelStart < PC.ChatSelEnd) return PC.ChatSelStart;
    return PC.ChatSelEnd;
}

function int ChatSelMaxIdx(OLTogetherController PC)
{
    if (PC.ChatSelStart > PC.ChatSelEnd) return PC.ChatSelStart;
    return PC.ChatSelEnd;
}

function int ChatHitTestCaret(OLTogetherController PC, float ScreenX)
{
    local float X, W, HScroll, CharX, PrevX;
    local int I, N;
    local string Prefix;

    if (PC == None) return 0;
    X = ChatInputX;
    W = ChatInputW;
    HScroll = ChatInputScroll;
    Prefix = "> ";
    N = Len(PC.ChatText);

    PrevX = 0.0;
    for (I = 0; I <= N; I++)
    {
        CharX = X + MeasureW(Prefix $ Left(PC.ChatText, I), 0.72 * UIScale) - HScroll;
        if (I > 0 && ScreenX < (PrevX + CharX) * 0.5)
            return I - 1;
        PrevX = CharX;
    }
    return N;
}

function NoteChatCaretMove()
{
    LastCaretMoveTime = WorldInfo.TimeSeconds;
}

function DrawScrollbar(float X, float Y, float H, int Total, int Visible, int StartRowIndex, float GA)
{
    local float TrackW, ThumbH, ThumbY, Ratio;

    TrackW = FMax(3.0, 4.0 * UIScale);
    DrawFilledBox(X, Y, TrackW, H, 35, 37, 42, byte(160.0 * GA));

    Ratio = float(Visible) / float(Total);
    ThumbH = FMax(H * Ratio, 12.0 * UIScale);
    if (Total > Visible)
        ThumbY = Y + (H - ThumbH) * (float(StartRowIndex) / float(Total - Visible));
    else
        ThumbY = Y;

    DrawFilledBox(X, ThumbY, TrackW, ThumbH, 130, 132, 140, byte(230.0 * GA));
}

function bool IsAtMainMenuScreen()
{
    local OLGame G;

    // The main menu / title screen is the state before any checkpoint has been
    // entered, i.e. the current checkpoint name is still unset ('None').
    G = OLGame(WorldInfo.Game);
    if (G != None)
        return G.CurrentCheckpointName == 'None';

    return false;
}

function DrawMainMenuInfo(OLTogetherController PC)
{
    local float X, Y, LineH, TextScale;
    local string NameLine;

    TextScale = 0.85 * UIScale;
    LineH = MeasureH("Ag", TextScale) + 3.0 * UIScale;

    X = 22.0 * UIScale;
    Y = 22.0 * UIScale;

    NameLine = "Logged in as: " $ (PC.LocalPlayerName != "" ? PC.LocalPlayerName : "Player");

    DrawLabel("Multiplayer v" $ ModVersion, X, Y, TextScale, 218, 196, 174, 248);
    Y += LineH;
    DrawLabel(NameLine, X, Y, TextScale, 210, 212, 220, 235);
    Y += LineH;
    DrawLabel("Enjoy your stay!", X, Y, TextScale, 150, 152, 160, 220);
}

function DrawSpeedrunHUD(OLTogetherController PC)
{
    local float X, Y, TextScale, TimeElapsed, CDScale, Pulse, Alpha;
    local string TimerText, CDText;
    local int Min, Sec, Ms;

    TextScale = 1.0 * UIScale;

    if (!PC.bSpeedrunMode)
        return;

    if (PC.bSpeedrunSequenceActive)
    {
        if (PC.SpeedrunCountdownStartTime <= 0.0)
        {
            // "Starting race..." phase
            Alpha = 0.6 + 0.4 * Cos(WorldInfo.TimeSeconds * 3.0);
            DrawLabel("STARTING RACE...",
                ViewW() * 0.5 - MeasureW("STARTING RACE...", TextScale * 1.2) * 0.5,
                ViewH() * 0.45, TextScale * 1.2,
                255, 200, 100, byte(255.0 * FClamp(Alpha, 0.0, 1.0)));
        }
        else
        {
            // Dramatic countdown
            CDScale = TextScale * (4.5 + 1.5 * Cos(WorldInfo.TimeSeconds * 8.0));
            Pulse = PC.SpeedrunOverlayPulse;
            Alpha = byte(255.0 * FClamp(0.7 + 0.3 * Sin(Pulse), 0.0, 1.0));
            CDText = string(PC.SpeedrunCountdownValue);
            if (PC.SpeedrunCountdownValue == 1)
            {
                DrawLabel(CDText,
                    ViewW() * 0.5 - MeasureW(CDText, CDScale) * 0.5,
                    ViewH() * 0.42 - MeasureH(CDText, CDScale) * 0.5,
                    CDScale, 255, 80, 80, Alpha);
            }
            else
            {
                DrawLabel(CDText,
                    ViewW() * 0.5 - MeasureW(CDText, CDScale) * 0.5,
                    ViewH() * 0.42 - MeasureH(CDText, CDScale) * 0.5,
                    CDScale, 255, 220, 120, Alpha);
            }

            // GO! flash
            if (PC.SpeedrunCountdownValue == 0)
            {
                DrawLabel("GO!",
                    ViewW() * 0.5 - MeasureW("GO!", TextScale * 3.0) * 0.5,
                    ViewH() * 0.55,
                    TextScale * 3.0, 120, 255, 120, Alpha);
            }
        }

        // Dramatic overlay vignette
        DrawFilledBox(0, 0, ViewW(), ViewH(), 0, 0, 0, byte(PC.SpeedrunOverlayAlpha * 80.0));
        DrawFilledBox(ViewW() * 0.1, ViewH() * 0.3, ViewW() * 0.8, ViewH() * 0.4, 0, 0, 0, byte(PC.SpeedrunOverlayAlpha * 40.0));
    }
    else if (!PC.bSpeedrunCountdownActive && PC.SpeedrunStartTime == 0.0 && !PC.bSpeedrunSequenceActive)
    {
        // Pre-race: show ready state
        X = ViewW() * 0.5;
        Y = 60.0 * UIScale;
        if (PC.bSpeedrunReady)
            DrawLabel("READY", X - MeasureW("READY", TextScale) * 0.5, Y, TextScale, 120, 200, 120, 255);
        else
            DrawLabel("H to Ready", X - MeasureW("H to Ready", TextScale) * 0.5, Y, TextScale, 200, 200, 120, 220);
    }

    // Timer display (bottom-left corner)
    if (PC.SpeedrunStartTime > 0.0)
    {
        TimeElapsed = WorldInfo.TimeSeconds - PC.SpeedrunStartTime;
        Min = int(TimeElapsed) / 60;
        Sec = int(TimeElapsed) % 60;
        Ms = int((TimeElapsed % 1.0) * 100.0);
        if (Min > 0)
            TimerText = string(Min) $ ":" $ (Sec < 10 ? "0" : "") $ string(Sec) $ "." $ (Ms < 10 ? "0" : "") $ string(Ms);
        else
            TimerText = string(Sec) $ "." $ (Ms < 10 ? "0" : "") $ string(Ms);

        DrawLabel(TimerText,
            20.0 * UIScale,
            ViewH() - 30.0 * UIScale,
            TextScale * 1.5, 220, 220, 240, 255);
    }
}

// ============================================================================
//  In-game settings menu
// ============================================================================

function OpenSettingsMenu()
{
    bSettingsOpen = true;
    SettingsOpenTarget = 1.0;
    SettingsTab = 0;
    SettingsHighlightedRow = 0;
    HoveredSettingsRow = -1;
    HoveredSettingsTab = -1;
    ModelScroll = 0;
    bRebindListening = false;
    RebindSlotIndex = -1;
    SettingsTabAnim = 1.0;
    SettingsTabTarget = 1.0;
    // Pick a random entrance style each time it opens.
    SettingsOpenAnimVariant = Rand(NUM_SETTINGS_ANIMS);
}

function CloseSettingsMenu()
{
    bSettingsOpen = false;
    SettingsOpenTarget = 0.0;
    // A fresh style for the exit as well.
    SettingsOpenAnimVariant = Rand(NUM_SETTINGS_ANIMS);
}

function ToggleSettingsMenu()
{
    if (bSettingsOpen)
        CloseSettingsMenu();
    else
        OpenSettingsMenu();
}

// ---- Tab model ------------------------------------------------------------
// The settings menu is organised into tabs. Each tab exposes a list of rows,
// and SettingsHighlightedRow is a plain 0-based index within the active tab.

function int NumSettingsTabs()
{
    return 4;
}

function string SettingsTabName(int TabIndex)
{
    switch (TabIndex)
    {
        case 0: return "General";
        case 1: return "Voice";
        case 2: return "Keybinds";
        case 3: return "Models";
    }
    return "";
}

function int NumSettingsRows()
{
    switch (SettingsTab)
    {
        case 0: return 7; // General
        case 1: return 4; // Voice
        case 2: return 4; // Keybinds
        case 3: return NUM_MODEL_ROWS; // Models
    }
    return 0;
}

function CaptureRebindKey(OLTogetherController PC, name Key)
{
    switch (RebindSlotIndex)
    {
        case 0: PC.BindOpenSettings = Key; break;
        case 1: PC.BindSpeedrunReady = Key; break;
        case 2: PC.BindPushToTalk = Key; break;
        case 3: PC.BindForceStart = Key; break;
    }
    bRebindListening = false;
    RebindSlotIndex = -1;
    PC.SaveConfig();
}

// Kept for callers that still ask whether the keybinds tab is active.
function bool InRebindTab()
{
    return SettingsTab == 2;
}

function string SettingsRowLabel(OLTogetherController PC, int RowIndex)
{
    switch (SettingsTab)
    {
        case 0:
            switch (RowIndex)
            {
                case 0: return "Pause On Lost Focus";
                case 1: return "Mouse Smoothing";
                case 2: return "Hide Player Names";
                case 3: return "Auto Reconnect";
                case 4: return "Reconnect Delay";
                case 5: return "Nearby Player Fade";
                case 6: return "Mute All Remote Players";
            }
            break;
        case 1:
            switch (RowIndex)
            {
                case 0: return "Mute Everyone";
                case 1: return "Push To Talk";
                case 2: return "Voice Proximity";
                case 3: return "Mute All Remote Players";
            }
            break;
        case 2:
            switch (RowIndex)
            {
                case 0: return "Open Settings";
                case 1: return "Toggle Ready";
                case 2: return "Push To Talk";
                case 3: return "Force Start";
            }
            break;
        case 3:
            return PC.GetModelName(RowIndex);
    }
    return "";
}

function string SettingsRowValue(OLTogetherController PC, int RowIndex)
{
    if (PC.Settings == None)
        return "";

    switch (SettingsTab)
    {
        case 0:
            switch (RowIndex)
            {
                case 0: return PC.Settings.bPauseOnLossFocus ? "[x]" : "[ ]";
                case 1: return (PC.PlayerInput != None && PC.PlayerInput.bEnableMouseSmoothing) ? "[x]" : "[ ]";
                case 2: return PC.Settings.bHidePlayerNames ? "[x]" : "[ ]";
                case 3: return PC.Settings.bAutoReconnect ? "[x]" : "[ ]";
                case 4: return int(PC.Settings.ReconnectDelay) $ "s";
                case 5: return PC.Settings.bFadeNearbyPlayers ? "[x]" : "[ ]";
                case 6: return PC.Settings.bMuteRemotePlayer ? "[x]" : "[ ]";
            }
            break;
        case 1:
            switch (RowIndex)
            {
                case 0: return PC.Settings.bMuteEveryone ? "[x]" : "[ ]";
                case 1: return PC.Settings.bPushToTalk ? "[x]" : "[ ]";
                case 2: return int(PC.Settings.VoiceProximityNear) $ "/" $ int(PC.Settings.VoiceProximityFar);
                case 3: return PC.Settings.bMuteRemotePlayer ? "[x]" : "[ ]";
            }
            break;
        case 2:
            if (bRebindListening && RebindSlotIndex == RowIndex)
                return "Press key...";
            switch (RowIndex)
            {
                case 0: return string(PC.BindOpenSettings);
                case 1: return string(PC.BindSpeedrunReady);
                case 2: return string(PC.BindPushToTalk);
                case 3: return string(PC.BindForceStart);
            }
            break;
        case 3:
            return (RowIndex == PC.LocalModelIndex) ? "[x]" : "";
    }
    return "";
}

function SettingsMoveSelection(int Delta)
{
    local int Max;
    Max = NumSettingsRows();
    if (Max <= 0)
        return;
    SettingsHighlightedRow += Delta;
    if (SettingsHighlightedRow < 0)
        SettingsHighlightedRow = Max - 1;
    if (SettingsHighlightedRow >= Max)
        SettingsHighlightedRow = 0;
    ClampModelScroll();
}

function CycleSettingsTab(int Delta)
{
    SettingsTab += Delta;
    if (SettingsTab < 0)
        SettingsTab = NumSettingsTabs() - 1;
    if (SettingsTab >= NumSettingsTabs())
        SettingsTab = 0;
    SettingsHighlightedRow = 0;
    ModelScroll = 0;
    bRebindListening = false;
    RebindSlotIndex = -1;
    SettingsTabAnim = 0.0;
    SettingsTabTarget = 1.0;
    SettingsTabTransitionVariant = Rand(NUM_SETTINGS_ANIMS);
}

// Keeps the highlighted model row within the visible scroll window.
function ClampModelScroll()
{
    if (SettingsTab != 3)
        return;
    if (SettingsHighlightedRow < ModelScroll)
        ModelScroll = SettingsHighlightedRow;
    if (SettingsHighlightedRow >= ModelScroll + MODEL_VISIBLE_ROWS)
        ModelScroll = SettingsHighlightedRow - MODEL_VISIBLE_ROWS + 1;
    if (ModelScroll < 0)
        ModelScroll = 0;
}

function SettingsMenuClick(OLTogetherController PC)
{
    // Clicking a tab header switches tabs.
    if (HoveredSettingsTab >= 0 && HoveredSettingsTab != SettingsTab)
    {
        SettingsTab = HoveredSettingsTab;
        SettingsHighlightedRow = 0;
        ModelScroll = 0;
        bRebindListening = false;
        RebindSlotIndex = -1;
        SettingsTabAnim = 0.0;
        SettingsTabTarget = 1.0;
        SettingsTabTransitionVariant = Rand(NUM_SETTINGS_ANIMS);
        return;
    }

    if (HoveredSettingsRow >= 0)
        SettingsHighlightedRow = HoveredSettingsRow;

    // On the keybinds tab a click begins listening for a new key.
    if (SettingsTab == 2 && !bRebindListening)
    {
        bRebindListening = true;
        RebindSlotIndex = SettingsHighlightedRow;
        return;
    }

    SettingsAdjust(PC, 0);
}

function SettingsAdjust(OLTogetherController PC, int Direction)
{
    if (PC.Settings == None)
        return;

    if (SettingsTab == 2)
    {
        if (!bRebindListening)
        {
            bRebindListening = true;
            RebindSlotIndex = SettingsHighlightedRow;
        }
        return;
    }

    if (SettingsTab == 3)
    {
        PC.ApplyLocalModel(SettingsHighlightedRow);
        return;
    }

    if (SettingsTab == 0)
    {
        switch (SettingsHighlightedRow)
        {
            case 0:
                PC.Settings.bPauseOnLossFocus = !PC.Settings.bPauseOnLossFocus;
                PC.ConsoleCommand("set Engine.GameViewportClient bPauseOnLossOfFocus " $ (PC.Settings.bPauseOnLossFocus ? "True" : "False"));
                break;
            case 1:
                if (PC.PlayerInput != None)
                {
                    PC.PlayerInput.bEnableMouseSmoothing = !PC.PlayerInput.bEnableMouseSmoothing;
                    PC.PlayerInput.SaveConfig();
                }
                break;
            case 2:
                PC.Settings.bHidePlayerNames = !PC.Settings.bHidePlayerNames;
                break;
            case 3:
                PC.Settings.bAutoReconnect = !PC.Settings.bAutoReconnect;
                break;
            case 4:
                if (Direction == 0)
                {
                    // Click cycles the delay up in 1s steps and wraps back to 1s.
                    PC.Settings.ReconnectDelay += 1.0;
                    if (PC.Settings.ReconnectDelay > 30.0)
                        PC.Settings.ReconnectDelay = 1.0;
                }
                else
                    PC.Settings.ReconnectDelay = FClamp(PC.Settings.ReconnectDelay + Direction * 1.0, 1.0, 60.0);
                PC.Settings.bAutoReconnect = true;
                break;
            case 5:
                PC.Settings.bFadeNearbyPlayers = !PC.Settings.bFadeNearbyPlayers;
                if (PC.ConnectionLink != None)
                    PC.ConnectionLink.bFadeNearbyPlayers = PC.Settings.bFadeNearbyPlayers;
                break;
            case 6:
                PC.Settings.bMuteRemotePlayer = !PC.Settings.bMuteRemotePlayer;
                break;
        }
    }
    else if (SettingsTab == 1)
    {
        switch (SettingsHighlightedRow)
        {
            case 0:
                PC.Settings.bMuteEveryone = !PC.Settings.bMuteEveryone;
                break;
            case 1:
                PC.Settings.bPushToTalk = !PC.Settings.bPushToTalk;
                if (PC.Settings.bPushToTalk)
                    PC.bMicTransmitting = false;
                else
                    PC.bMicTransmitting = true;
                break;
            case 2:
                if (Direction != 0)
                {
                    PC.Settings.VoiceProximityNear = FClamp(PC.Settings.VoiceProximityNear + Direction * 100.0, 200.0, 2000.0);
                    PC.Settings.VoiceProximityFar = FClamp(PC.Settings.VoiceProximityFar + Direction * 200.0, 500.0, 5000.0);
                }
                break;
            case 3:
                PC.Settings.bMuteRemotePlayer = !PC.Settings.bMuteRemotePlayer;
                break;
        }
    }

    PC.Settings.SaveConfig();
    PC.ApplySettings();
}

// Returns a per-frame (alpha, offsetX, offsetY, scale) tuple describing the
// active open/close animation. 16 distinct styles keep the menu feeling fresh.
function GetSettingsOpenAnimState(out float OutAlpha, out float OutOffX, out float OutOffY, out float OutScale)
{
    local float T, E, Inv;

    T = FClamp(SettingsOpenAnim, 0.0, 1.0);
    // Smoothstep easing for a soft settle.
    E = T * T * (3.0 - 2.0 * T);
    Inv = 1.0 - E;

    OutAlpha = E;
    OutOffX = 0.0;
    OutOffY = 0.0;
    OutScale = 1.0;

    switch (SettingsOpenAnimVariant)
    {
        case 0:  OutOffY = Inv * -80.0 * UIScale; break;                 // slide from top
        case 1:  OutOffY = Inv *  80.0 * UIScale; break;                 // slide from bottom
        case 2:  OutOffX = Inv * -120.0 * UIScale; break;                // slide from left
        case 3:  OutOffX = Inv *  120.0 * UIScale; break;                // slide from right
        case 4:  OutScale = 0.6 + 0.4 * E; break;                        // zoom in
        case 5:  OutScale = 1.4 - 0.4 * E; break;                        // zoom out
        case 6:  OutOffX = Inv * -120.0 * UIScale; OutOffY = Inv * -80.0 * UIScale; break; // diagonal TL
        case 7:  OutOffX = Inv *  120.0 * UIScale; OutOffY = Inv *  80.0 * UIScale; break; // diagonal BR
        case 8:  OutScale = 0.5 + 0.5 * E; OutOffY = Inv * 40.0 * UIScale; break;          // rise + zoom
        case 9:  OutOffY = Inv * -140.0 * UIScale; OutScale = 0.85 + 0.15 * E; break;      // drop + settle
        case 10: OutAlpha = E * E; break;                                // slow fade
        case 11: OutAlpha = 1.0 - Inv * Inv; break;                      // fast fade
        case 12: OutScale = 0.9 + 0.1 * Sin(E * 3.1415927); OutAlpha = E; break; // gentle pulse
        case 13: OutOffX = Inv * Sin(T * 18.0) * 30.0 * UIScale; break;  // shake in
        case 14: OutOffY = Inv * 100.0 * UIScale; OutScale = 1.15 - 0.15 * E; break;       // overshoot up
        case 15: OutScale = 0.3 + 0.7 * E; OutAlpha = E; break;          // strong zoom
        default: break;
    }
}

function UpdateSettingsOpenAnimation(float Delta)
{
    local float Rate;
    Rate = 9.0;
    SettingsOpenAnim += (SettingsOpenTarget - SettingsOpenAnim) * FMin(1.0, Delta * Rate);
    SettingsOpenAnim = FClamp(SettingsOpenAnim, 0.0, 1.0);
    SettingsTabAnim += (SettingsTabTarget - SettingsTabAnim) * FMin(1.0, Delta * Rate);
    SettingsTabAnim = FClamp(SettingsTabAnim, 0.0, 1.0);
}

function Texture2D GetCursorTex()
{
    if (CachedCursorTex == None)
        CachedCursorTex = Texture2D(DynamicLoadObject("menuassets.MouseCursor", class'Texture2D', true));
    return CachedCursorTex;
}

function DrawCursor(float Alpha)
{
    local float S;
    local byte A;
    local Texture2D Tex;
    local LinearColor LC;

    A = byte(255.0 * Alpha);
    Tex = GetCursorTex();
    if (Tex != None)
    {
        // Anchor the cursor image by its top-left at the mouse point.
        S = 32.0 * UIScale;
        LC.R = 1.0;
        LC.G = 1.0;
        LC.B = 1.0;
        LC.A = Alpha;
        Canvas.SetPos(MouseX, MouseY);
        Canvas.DrawTile(Tex, S, S, 0.0, 0.0, Tex.SizeX, Tex.SizeY, LC);
        return;
    }

    // Fallback square cursor if the texture fails to load.
    S = 12.0 * UIScale;
    A = byte(220.0 * Alpha);
    Canvas.SetPos(MouseX - S * 0.5, MouseY - S * 0.5);
    Canvas.SetDrawColor(220, 222, 230, A);
    Canvas.DrawRect(S, S);
    Canvas.SetPos(MouseX - 1, MouseY - 1);
    Canvas.SetDrawColor(30, 32, 36, A);
    Canvas.DrawRect(2, 2);
}

// Returns chat panel animation offsets based on variant (0-7 different styles)
function GetChatAnimOffsets(out float OutOffX, out float OutOffY, out float OutScale)
{
    local float T, Inv;
    T = FClamp(ChatVisibilityAlpha, 0.0, 1.0);
    Inv = 1.0 - T;

    OutOffX = 0.0;
    OutOffY = 0.0;
    OutScale = 1.0;

    switch (ChatAnimVariant)
    {
        case 0: OutOffX = Inv * -30.0 * UIScale; OutOffY = Inv * 20.0 * UIScale; break; // slide from left-top
        case 1: OutOffY = Inv * 40.0 * UIScale; break; // slide up from bottom
        case 2: OutScale = 0.8 + 0.2 * T; break; // quick zoom in
        case 3: OutOffX = Inv * 20.0 * UIScale; break; // slide from right
        case 4: OutScale = 1.0 + Inv * 0.1; OutOffY = Inv * 10.0 * UIScale; break; // overshoot
        case 5: OutOffY = Inv * -20.0 * UIScale; OutScale = 0.9 + 0.1 * Sin(T * 3.14159); break; // bounce
        case 6: OutScale = 0.5 + 0.5 * T; break; // slow fade + scale up
        case 7: OutOffY = Inv * 60.0 * UIScale; OutScale = 1.1 - 0.1 * T; break; // drop + settle
        default: break;
    }
}

function DrawSettingsMenu(OLTogetherController PC)
{
    local float A, OffX, OffY, Sc;
    local float PanelW, PanelH, PanelX, PanelY, Pad, RowH, HeaderH;
    local float CX, CY, TitleScale, RowScale, ValScale;
    local int I, Rows, VisibleRows, StartIdx, EndIdx;
    local string Val;
    local byte BaseA;
    local float TabW, TabX, TabY, TabH, TabScale;
    local string TabLabel;
    local OLTogetherInput Input;

    if (SettingsOpenAnim <= 0.01 && !bSettingsOpen)
        return;

    if (bRebindListening && RebindSlotIndex < 0)
        bRebindListening = false;

    HoveredSettingsRow = -1;
    HoveredSettingsTab = -1;

    GetSettingsOpenAnimState(A, OffX, OffY, Sc);
    if (A <= 0.01)
        return;

    Rows = NumSettingsRows();

    TitleScale = 1.05 * UIScale * Sc;
    RowScale = 0.85 * UIScale * Sc;
    ValScale = 0.85 * UIScale * Sc;
    TabScale = 0.78 * UIScale * Sc;
    Pad = 18.0 * UIScale * Sc;
    RowH = MeasureH("Ag", RowScale) + 14.0 * UIScale * Sc;
    TabH = MeasureH("Ag", TabScale) + 14.0 * UIScale * Sc;
    HeaderH = MeasureH("Ag", TitleScale) + 20.0 * UIScale * Sc;

    PanelW = FClamp(ViewW() * 0.34, 360.0 * UIScale, 620.0 * UIScale) * Sc;

    VisibleRows = Rows;
    if (SettingsTab == 3 && Rows > MODEL_VISIBLE_ROWS)
        VisibleRows = MODEL_VISIBLE_ROWS;

    PanelH = HeaderH + TabH + RowH * VisibleRows + Pad * 2.0;

    PanelX = (ViewW() - PanelW) * 0.5 + OffX;
    PanelY = (ViewH() - PanelH) * 0.5 + OffY;

    // Sync mouse position from input
    Input = OLTogetherInput(PC.PlayerInput);
    if (Input != None)
    {
        MouseX = Input.MousePosition.X;
        MouseY = Input.MousePosition.Y;
    }

    // Dim the world behind the menu.
    DrawFilledBox(0, 0, ViewW(), ViewH(), 0, 0, 0, byte(150.0 * A));

    DrawPanel(PanelX, PanelY, PanelW, PanelH, A);

    CX = PanelX + Pad;
    CY = PanelY + Pad;

    DrawLabel("Multiplayer Settings", CX, CY, TitleScale, 232, 210, 188, byte(255.0 * A));
    CY += HeaderH;

    // ---- Tab strip ---------------------------------------------------------
    TabW = (PanelW - Pad * 2.0) / float(NumSettingsTabs());
    for (I = 0; I < NumSettingsTabs(); I++)
    {
        TabX = PanelX + Pad + I * TabW;
        TabY = CY;
        TabLabel = SettingsTabName(I);

        if (MouseX >= TabX && MouseX < TabX + TabW - 1.0 * UIScale
            && MouseY >= TabY && MouseY < TabY + TabH)
        {
            HoveredSettingsTab = I;
            DrawFilledBox(TabX, TabY, TabW - 2.0 * UIScale, TabH,
                          70, 120, 90, byte(150.0 * A));
        }
        else if (I == SettingsTab)
        {
            DrawFilledBox(TabX, TabY, TabW - 2.0 * UIScale, TabH,
                          70, 90, 120, byte(150.0 * A));
        }
        else
        {
            DrawFilledBox(TabX, TabY, TabW - 2.0 * UIScale, TabH,
                          30, 32, 38, byte(120.0 * A));
        }

        DrawLabel(TabLabel, TabX + 4.0 * UIScale, TabY + 3.0 * UIScale,
                  TabScale, 220, 222, 230, byte(255.0 * A));
    }
    CY += TabH + Pad * 0.5;

    // ---- Rows --------------------------------------------------------------
    StartIdx = (SettingsTab == 3) ? ModelScroll : 0;
    EndIdx = StartIdx + VisibleRows;
    if (EndIdx > Rows)
        EndIdx = Rows;

    for (I = StartIdx; I < EndIdx; I++)
    {
        BaseA = byte(255.0 * A);

        if (MouseY >= CY - 3.0 * UIScale && MouseY < CY + RowH - 3.0 * UIScale
            && MouseX >= PanelX + Pad * 0.5 && MouseX < PanelX + PanelW - Pad * 0.5)
        {
            HoveredSettingsRow = I;
            DrawFilledBox(PanelX + Pad * 0.5, CY - 3.0 * UIScale, PanelW - Pad, RowH,
                          70, 120, 90, byte(140.0 * A));
        }
        else if (I == SettingsHighlightedRow)
        {
            DrawFilledBox(PanelX + Pad * 0.5, CY - 3.0 * UIScale, PanelW - Pad, RowH,
                          70, 90, 120, byte(120.0 * A));
        }

        DrawLabel(SettingsRowLabel(PC, I), CX, CY, RowScale,
                  byte(230), byte(232), byte(240), BaseA);

        Val = SettingsRowValue(PC, I);
        if (Val != "")
            DrawLabel(Val, PanelX + PanelW - Pad - MeasureW(Val, ValScale), CY, ValScale,
                      200, 220, 200, BaseA);

        CY += RowH;
    }

    // Models scrollbar
    if (SettingsTab == 3 && Rows > MODEL_VISIBLE_ROWS)
        DrawScrollbar(PanelX + PanelW - 5.0 * UIScale, CY - 3.0 * UIScale - RowH * VisibleRows,
                      RowH * VisibleRows, Rows, MODEL_VISIBLE_ROWS, ModelScroll, A);

    // Draw custom cursor
    DrawCursor(A);
}

event PostRender()
{
    local OLTogetherController PC;
    local float Delta;

    super.PostRender();

    PC = OLTogetherController(PlayerOwner);
    if (PC == None || Canvas == None)
        return;

    UIScale = FClamp(ViewH() / REF_HEIGHT, 0.75, 2.5);
    Canvas.Font = GetRobotoFont();

    Delta = WorldInfo.TimeSeconds - LastChatLineTime;
    if (Delta < 0.0 || Delta > 0.5)
        Delta = 0.016;
    LastChatLineTime = WorldInfo.TimeSeconds;

    UpdateChatAnimation(PC, Delta);
    UpdateSettingsOpenAnimation(Delta);
    UpdateEmojiPickerAnimation(Delta);
    NoPause();

    if (IsAtMainMenuScreen())
        DrawMainMenuInfo(PC);

    DrawNotificationsPanel();
    if (PC.Settings == None || !PC.Settings.bHidePlayerNames)
        DrawNameTag(PC);
    DrawChatPanel(PC);
    DrawSpeedrunHUD(PC);
    DrawSettingsMenu(PC);
}

DefaultProperties
{
    MaxChatHistory=200
    ChatScrollIndex=0
    UIScale=1.0
    ChatVisibilityAlpha=1.0
    ChatPanelOpenAnim=0.0
    ChatIdleFadeDelay=8.0
    ChatFadeDuration=1.5
    NameFadeStartDist=800.0
    NameFadeEndDist=2500.0
    NameNearFadeStart=220.0
    NameNearFadeEnd=90.0
    ModVersion="1.0"
}
