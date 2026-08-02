class OLTogetherController extends OLPlayerController;

struct RemotePlayerData
{
    var int CID;
    var Pawn RemotePawn;
    var AIController RemoteCtrl;
    var string PlayerName;
    var int ModelIndex;
    var bool bTalking;
    var int Health;
};

var OLTogetherLink ConnectionLink;
var OLTogetherVoiceListener VoiceListener;
var float LastVoiceControlSendTime;
var bool bLastSentTalking;
var int PlayerRole;
var float LastPingSendTime;
var int RoundTripPingMs;
var string ServerAddress, ServerPort, ConnectionState, RoomAuthToken;
var string VoiceHost, VoicePort;
var string LocalPlayerName, LastSentPlayerName;
var bool bPlayerNameAnnounced;
var float LastPlayerNameSendTime;
var bool bChatMode;
var string ChatText;
var int ChatCaretPos;
var int ChatSelStart;
var int ChatSelEnd;
var OLTogetherSettings Settings;
var bool bSettingsMenuOpen;
var bool bSpeedrunMode, bSpeedrunReady, bSpeedrunCountdownActive, bPeerIsReady;
var bool bSpeedrunSequenceActive, bSpeedrunControlsLocked, bHideLocalPawnDuringSpeedrun;
var float SpeedrunStartTime, SpeedrunFinishTime, SpeedrunSequenceStartTime, SpeedrunStartDelay;
var float SpeedrunCountdownStartTime, SpeedrunCountdownElapsed;
var int SpeedrunCountdownValue;
var vector SpeedrunLockLocation;
var rotator SpeedrunLockRotation;
var float SpeedrunOverlayAlpha, SpeedrunOverlayPulse;
var bool bInStartNewGame, bStartedAtCheckpoint;
var float DisconnectedSince, LastReconnectAttempt;
var bool bWasConnected;
var bool bMicTransmitting;
var config name BindSpeedrunReady, BindForceStart, BindPushToTalk, BindOpenSettings;
var int LocalModelIndex;
var bool bModelAnnounced;
var int LastSentModelIndex;
var float LastModelSendTime;
var Pawn LastModeledPawn;
var int LastSentSpecialMove;
var int MyPlayerCid;
var float LastStateSentTime;
var float IdleStateSendInterval;
var float ActiveStateSendInterval;

// Door sync state tracking - continue sending after release
var OLDoor LastActiveDoor;
var float LastDoorSyncTime;
var int LastDoorSyncId;
var float LastDoorOpenRatio;

const NUM_PLAYER_MODELS = 11;

var array<RemotePlayerData> RemotePlayers;

function string GetModelName(int Idx)
{
    switch (Idx)
    {
        case 0:  return "Miles Upshur";
        case 1:  return "Faith";
        case 2:  return "Father Martin";
        case 3:  return "Glitchtrap";
        case 4:  return "Richard Trager";
        case 5:  return "Miles Upshur (Beta)";
        case 6:  return "Chris Walker";
        case 7:  return "Eddie Gluskin";
        case 8:  return "Miles Upshur (Fingerless)";
        case 9:  return "Waylon Park (Prisoner)";
        case 10: return "Waylon Park";
    }
    return "Miles Upshur";
}

function string GetModelBodyPath(int Idx)
{
    switch (Idx)
    {
        case 0:  return "02_Player.Pawn.Miles_beheaded";
        case 1:  return "FaithPMContent.Meshes.Faith_Body";
        case 2:  return "FatherMartinPM.FatherMartinRigged";
        case 3:  return "Glitchy_Boi.Glitchy_Boi";
        case 4:  return "SurgeonPM.Meshes.Surgeon_Body";
        case 5:  return "MilesPM.Meshes.Miles_Body";
        case 6:  return "ChrisPM.Meshes.Soldier_Body";
        case 7:  return "EddiePM.Meshes.Eddie_Body";
        case 8:  return "02_Player.Pawn.Miles_beheaded_fingerless";
        case 9:  return "02_Waylon_Park.Mesh.Waylon_Park";
        case 10: return "02_Waylon_Park.Mesh.Waylon_Park_IT";
    }
    return "02_Player.Pawn.Miles_beheaded";
}

function string GetModelHeadPath(int Idx)
{
    switch (Idx)
    {
        case 0:  return "02_Player.Pawn.Miles_head";
        case 1:  return "FaithPMContent.Meshes.Faith_Head";
        case 2:  return "FatherMartinPM.FatherMarinHead";
        case 3:  return "Glitchy_Boi.Head";
        case 4:  return "SurgeonPM.Meshes.Surgeon_Head_Head";
        case 5:  return "MilesPM.Meshes.Miles_Head";
        case 6:  return "ChrisPM.Meshes.Soldier_Body";
        case 7:  return "EddiePM.Meshes.Eddie_Head";
        case 8:  return "02_Player.Pawn.Miles_head";
        case 9:  return "02_Player.Pawn.Miles_head";
        case 10: return "02_Player.Pawn.Miles_head";
    }
    return "02_Player.Pawn.Miles_head";
}

function ApplyModelToHero(OLHero H, int Idx, bool bLocalOwner)
{
    local SkeletalMesh BodyMesh;
    local StaticMesh HeadStatic;
    if (H == None) return;
    BodyMesh = SkeletalMesh(DynamicLoadObject(GetModelBodyPath(Idx), class'SkeletalMesh', true));
    HeadStatic = StaticMesh(DynamicLoadObject(GetModelHeadPath(Idx), class'StaticMesh', true));
    if (BodyMesh != None)
    {
        if (H.Mesh != None) H.Mesh.SetSkeletalMesh(BodyMesh);
        if (H.ShadowProxy != None) H.ShadowProxy.SetSkeletalMesh(BodyMesh);
    }
    if (H.HeadMesh != None && HeadStatic != None)
    {
        H.HeadMesh.SetStaticMesh(HeadStatic);
        H.HeadMesh.SetOwnerNoSee(bLocalOwner);
        H.HeadMesh.SetHidden(bLocalOwner ? true : bHideLocalPawnDuringSpeedrun);
        H.HeadMesh.CastShadow = true;
        H.HeadMesh.bCastHiddenShadow = true;
    }
}

function ApplyLocalModel(int Idx)
{
    if (Idx < 0) Idx = NUM_PLAYER_MODELS - 1;
    if (Idx >= NUM_PLAYER_MODELS) Idx = 0;
    LocalModelIndex = Idx;
    ApplyModelToHero(OLHero(Pawn), Idx, true);
    if (Settings != None) { Settings.SelectedModelIndex = Idx; Settings.SaveConfig(); }
    bModelAnnounced = false;
    LastSentModelIndex = -1;
    if (ConnectionLink != None && ConnectionLink.bIsConnected)
        ConnectionLink.SendText("MODEL," $ Idx $ "\n");
    AddNotification("Model: " $ GetModelName(Idx));
}

exec function SetPlayerModel(int Idx) { ApplyLocalModel(Idx); }

function CyclePlayerModel(int Delta) { ApplyLocalModel(LocalModelIndex + Delta); }

function string GetUrlOptionValue(string Url, string OptionName)
{
    local array<string> Segments;
    local string KeyPrefix;
    local int Idx, FoundAt;
    KeyPrefix = OptionName $ "=";
    Segments = SplitString(Url, "?", true);
    for (Idx = 0; Idx < Segments.Length; Idx++)
    {
        FoundAt = InStr(Segments[Idx], KeyPrefix);
        if (FoundAt == 0)
            return Right(Segments[Idx], Len(Segments[Idx]) - Len(KeyPrefix));
    }
    return "";
}

function string ResolveUrl(string Url, string Key)
{
    local string V;
    V = WorldInfo.Game.ParseOption(Url, Key);
    if (V == "") V = GetUrlOptionValue(Url, Key);
    return V;
}

function int FindOrCreateRemote(int CID)
{
    local int Idx;
    local RemotePlayerData Entry;
    local OLHero RemoteHero, MyHero;

    for (Idx = 0; Idx < RemotePlayers.Length; Idx++)
    {
        if (RemotePlayers[Idx].CID == CID)
            return Idx;
    }

    Entry.CID = CID;
    Entry.PlayerName = "Player";
    Entry.Health = 100;

    if (Pawn != None)
    {
        Entry.RemotePawn = Spawn(class'OLTogetherRemoteHero',,, Pawn.Location, Pawn.Rotation,, true);
        if (Entry.RemotePawn != None)
        {
            Entry.RemoteCtrl = Spawn(class'OLTogetherRemoteControllerV2');
            if (Entry.RemoteCtrl != None)
                Entry.RemoteCtrl.Possess(Entry.RemotePawn, false);
            RemoteHero = OLHero(Entry.RemotePawn);
            if (RemoteHero != None)
            {
                MyHero = OLHero(Pawn);
                if (MyHero != None && MyHero.CameraMesh != None && RemoteHero.CameraMeshShadowProxy != None)
                    RemoteHero.CameraMeshShadowProxy.SetSkeletalMesh(MyHero.CameraMesh.SkeletalMesh);
                if (Entry.ModelIndex != 0)
                    ApplyModelToHero(RemoteHero, Entry.ModelIndex, false);
            }
        }
    }

    RemotePlayers.AddItem(Entry);
    return RemotePlayers.Length - 1;
}

event PostBeginPlay()
{
    local string Url, V, PortStr;
    local int ControlPort;

    super.PostBeginPlay();
    Url = WorldInfo.GetLocalURL();
    V = ResolveUrl(Url, "Role");
    PlayerRole = int(V);
    ServerAddress = "127.0.0.1";
    ServerPort = "7777";
    LocalPlayerName = "";

    V = ResolveUrl(Url, "ServerIP");
    if (V != "") ServerAddress = V;
    V = ResolveUrl(Url, "ServerPort");
    if (V != "") ServerPort = V;
    V = ResolveUrl(Url, "PlayerName");
    if (V != "") LocalPlayerName = V;
    if (LocalPlayerName == "")
        LocalPlayerName = "Player" @ (PlayerRole == 0 ? "Host" : "Client");

    bSpeedrunMode = (ResolveUrl(Url, "SpeedrunMode") == "1");
    V = ResolveUrl(Url, "PushToTalk");
    if (V == "1") Settings.bPushToTalk = true;
    RoomAuthToken = ResolveUrl(Url, "RoomToken");
    VoiceHost = ResolveUrl(Url, "VoiceHost");
    VoicePort = ResolveUrl(Url, "VoicePort");

    ConnectionState = "Connecting...";
    LastPingSendTime = 0.0;
    LastReconnectAttempt = -999.0;
    RoundTripPingMs = 0;
    bPlayerNameAnnounced = false;
    LastSentPlayerName = "";
    LastPlayerNameSendTime = -999.0;
    bChatMode = false;
    ChatText = "";
    ChatCaretPos = 0;
    ChatSelStart = 0;
    ChatSelEnd = 0;

    Settings = new(self) class'OLTogetherSettings';
    if (Settings != None)
    {
        Settings.SeedDefaults();
        ApplySettings();
        LocalModelIndex = Settings.SelectedModelIndex;
        if (LocalModelIndex < 0 || LocalModelIndex >= NUM_PLAYER_MODELS)
            LocalModelIndex = 0;
    }

    bMicTransmitting = (Settings == None || !Settings.bPushToTalk);

    ConnectionLink = Spawn(class'OLTogetherLink', self);
    if (ConnectionLink != None)
    {
        ConnectionLink.ControllerOwner = self;
        ConnectionLink.IP = ServerAddress;
        ConnectionLink.Port = ServerPort;
        ConnectionLink.SetServer(ServerAddress, ServerPort);
        if (Settings != None)
            ConnectionLink.bFadeNearbyPlayers = Settings.bFadeNearbyPlayers;
    }

    LastVoiceControlSendTime = -999.0;
    PortStr = ResolveUrl(Url, "ControlPort");
    if (PortStr != "") ControlPort = int(PortStr);
    else ControlPort = 6700;

    VoiceListener = Spawn(class'OLTogetherVoiceListener', self);
    if (VoiceListener != None)
        VoiceListener.Init(self, ControlPort);

    IdleStateSendInterval = 0.25;
    ActiveStateSendInterval = 0.033;
    LastStateSentTime = 0.0;
}

function HideSpeedrunPawn()
{
    local int Idx;
    for (Idx = 0; Idx < RemotePlayers.Length; Idx++)
    {
        if (RemotePlayers[Idx].RemotePawn != None)
            RemotePlayers[Idx].RemotePawn.SetHidden(true);
    }
    bHideLocalPawnDuringSpeedrun = true;
}

function ShowSpeedrunPawn()
{
    local int Idx;
    for (Idx = 0; Idx < RemotePlayers.Length; Idx++)
    {
        if (RemotePlayers[Idx].RemotePawn != None)
            RemotePlayers[Idx].RemotePawn.SetHidden(false);
    }
    bHideLocalPawnDuringSpeedrun = false;
}

function ResetSpeedrunState()
{
    bSpeedrunControlsLocked = false;
    IgnoreMoveInput(false);
    IgnoreLookInput(false);
    bSpeedrunReady = false;
    bPeerIsReady = false;
}

function ResetSpeedrunSequence()
{
    bSpeedrunCountdownActive = false;
    bSpeedrunSequenceActive = false;
    SpeedrunStartTime = WorldInfo.TimeSeconds;
    SpeedrunCountdownStartTime = 0.0;
    ResetSpeedrunState();
    ShowSpeedrunPawn();
    AddNotification("GO!");
}

function CountDownTickCommon(name TickName)
{
    local float T;
    T = WorldInfo.TimeSeconds - SpeedrunCountdownStartTime;
    SpeedrunCountdownElapsed = T;
    SpeedrunOverlayPulse += 0.06;
    SpeedrunOverlayAlpha = FMin(SpeedrunOverlayAlpha + 0.04, 0.85);
    SpeedrunCountdownValue = 5 - int(T);
    if (SpeedrunCountdownValue < 1) SpeedrunCountdownValue = 1;
    if (T >= 5.0)
    {
        SpeedrunCountdownValue = 0;
        SpeedrunCountdownElapsed = 5.0;
        ClearTimer(TickName);
        ResetSpeedrunSequence();
        if (ConnectionLink != None) ConnectionLink.SendText("SRUN,GO\n");
    }
}

function BeginSpeedrunCountdown(name TickName)
{
    SpeedrunCountdownValue = 5;
    SpeedrunCountdownStartTime = WorldInfo.TimeSeconds;
    SpeedrunCountdownElapsed = 0.0;
    SpeedrunOverlayPulse = 0.0;
    SetTimer(0.02, true, TickName);
}

function bool IsPawnMoving()
{
    local OLHero MyHero;
    MyHero = OLHero(Pawn);
    if (MyHero == None)
        return false;
    return VSize(Pawn.Velocity) > 50.0 || int(MyHero.SpecialMove) != 0;
}

function float GetCurrentSendInterval()
{
    if (IsPawnMoving() || LastSentSpecialMove != 0)
        return ActiveStateSendInterval;
    return IdleStateSendInterval;
}

function float GetDoorAnimRatio(OLHero H)
{
    if (H == None) return 0.0;
    if (H.ShadowProxyDoorAnimNode == None) return 0.0;
    return H.ShadowProxyDoorAnimNode.CurrentRatio;
}

// Door sync: identify which door the player is interacting with
// Uses door location as stable ID (both players have same level layout)
function int GetDoorSyncId(OLHero H)
{
    local int DoorId;
    
    if (H != None && H.ActiveDoor != None)
    {
        DoorId = int(H.ActiveDoor.Location.X * 7 + H.ActiveDoor.Location.Y * 13);
        LastActiveDoor = H.ActiveDoor;
        LastDoorSyncId = DoorId;
        LastDoorSyncTime = WorldInfo.TimeSeconds;
        return DoorId;
    }
    
    // After release, keep sending for up to 2s so remote door opens fully
    if (LastActiveDoor != None && WorldInfo.TimeSeconds - LastDoorSyncTime < 2.0)
        return LastDoorSyncId;
    
    LastActiveDoor = None;
    return 0;
}

function float GetDoorSyncOpenRatio(OLHero H)
{
    if (H != None && H.ActiveDoor != None)
    {
        LastDoorOpenRatio = H.ActiveDoor.OpenRatio;
        return H.ActiveDoor.OpenRatio;
    }
    
    // After release, keep reading the door's actual OpenRatio as it animates to 1.0
    if (LastActiveDoor != None && WorldInfo.TimeSeconds - LastDoorSyncTime < 2.0)
    {
        LastDoorOpenRatio = LastActiveDoor.OpenRatio;
        return LastActiveDoor.OpenRatio;
    }
    
    return -1.0;
}

event PlayerTick(float DeltaTime)
{
    local string Packet;
    local OLHero RemoteHero, MyHero;
    local int DoorState, LeanState, ExtraState, ExtraKind;
    local float GapToRemote, SendInterval;
    local bool bFadeNow;
    local int Idx;

    super.PlayerTick(DeltaTime);

    if (bSpeedrunControlsLocked)
    {
        if (bIgnoreMoveInput == 0) IgnoreMoveInput(true);
        if (bIgnoreLookInput == 0) IgnoreLookInput(true);
    }

    if (ConnectionLink != None && !ConnectionLink.bIsConnected && Settings != None && Settings.bAutoReconnect
        && WorldInfo.TimeSeconds - LastReconnectAttempt > FMax(1.0, Settings.ReconnectDelay))
    {
        LastReconnectAttempt = WorldInfo.TimeSeconds;
        ConnectionLink.Reconnect();
    }

    if (ConnectionLink != None && ConnectionLink.bIsConnected)
    {
        if (!bPlayerNameAnnounced || LocalPlayerName != LastSentPlayerName || WorldInfo.TimeSeconds - LastPlayerNameSendTime > 1.0)
        {
            ConnectionLink.SendText("NAME," $ LocalPlayerName $ "\n");
            bPlayerNameAnnounced = true;
            LastSentPlayerName = LocalPlayerName;
            LastPlayerNameSendTime = WorldInfo.TimeSeconds;
        }

        if (!bModelAnnounced || LocalModelIndex != LastSentModelIndex || WorldInfo.TimeSeconds - LastModelSendTime > 1.0)
        {
            ConnectionLink.SendText("MODEL," $ LocalModelIndex $ "\n");
            bModelAnnounced = true;
            LastSentModelIndex = LocalModelIndex;
            LastModelSendTime = WorldInfo.TimeSeconds;
        }

        if (WorldInfo.TimeSeconds - LastPingSendTime > 1.0)
        {
            LastPingSendTime = WorldInfo.TimeSeconds;
            ConnectionLink.SendText("PING," $ string(int(WorldInfo.TimeSeconds * 1000.0)) $ "\n");
        }

        if (bMicTransmitting != bLastSentTalking)
        {
            bLastSentTalking = bMicTransmitting;
            ConnectionLink.SendText("TALK," $ int(bMicTransmitting) $ "\n");
        }
    }

    if (ConnectionLink != None && ConnectionLink.bIsConnected && Pawn != None)
    {
        MyHero = OLHero(Pawn);
        SendInterval = GetCurrentSendInterval();

        if (MyHero != None && int(MyHero.SpecialMove) != LastSentSpecialMove)
        {
            if (int(MyHero.SpecialMove) != 0)
                ConnectionLink.SendText("SPECIAL_S," $ int(MyHero.SpecialMove) $ "," $ int(VSize(Pawn.Velocity) > 300.0) $ "\n");
            else
                ConnectionLink.SendText("SPECIAL_E\n");
            LastSentSpecialMove = int(MyHero.SpecialMove);
        }
        
        if (WorldInfo.TimeSeconds - LastStateSentTime >= SendInterval)
        {
            LastStateSentTime = WorldInfo.TimeSeconds;

            DoorState = 0;
            if (MyHero != None)
            {
                switch (int(MyHero.SpecialMove))
                {
                    case 28: case 29: case 30: case 31: case 32:
                        DoorState = int(MyHero.DoorOpeningType); break;
                    case 33: case 34:
                        DoorState = int(MyHero.DoorClosingType); break;
                }
                if (MyHero.ActiveDoor != None && (MyHero.SpecialMove >= 28 && MyHero.SpecialMove <= 34))
                {
                    `log("[DOOR_HOST] SM:" @ int(MyHero.SpecialMove) @ "DoorState:" @ DoorState @ "RevDir:" @ MyHero.ActiveDoor.bReverseDirection @ "DoorName:" @ MyHero.ActiveDoor @ "Time:" @ WorldInfo.TimeSeconds);
                }
            }

            LeanState = (bLeanInputLeft != 0) ? 1 : (bLeanInputRight != 0) ? 2 : 0;
            ExtraState = 0;
            ExtraKind = 0;
            if (MyHero != None)
            {
                ExtraState = int(MyHero.bLeftAnim);
                ExtraKind = int(MyHero.ActiveLedgeTransitionType);
            }

            Packet = "LOC,"
                $ WorldInfo.TimeSeconds $ ","
                $ Pawn.Location.X $ "," $ Pawn.Location.Y $ "," $ Pawn.Location.Z $ ","
                $ Rotation.Pitch $ "," $ Rotation.Yaw $ ","
                $ Pawn.Velocity.X $ "," $ Pawn.Velocity.Y $ "," $ Pawn.Velocity.Z $ ","
                $ int(Pawn.bIsCrouched) $ ","
                $ (MyHero != None ? int(MyHero.bCamcorderDesired) : 0) $ ","
                $ (MyHero != None ? int(MyHero.CamcorderState) : 0) $ ","
                $ (MyHero != None ? int(MyHero.LocomotionMode) : 0) $ ","
                $ (MyHero != None ? int(MyHero.SpecialMove) : 0) $ ","
                $ DoorState $ "," $ LeanState $ "," $ ExtraState $ "," $ ExtraKind $ ","
                $ (MyHero != None ? int(MyHero.PreciseHealth) : 100) $ ","
                $ (MyHero != None ? int(MyHero.bRunningTraversalMove) : 0) $ ","
                $ (MyHero != None ? int(MyHero.bPlayingSpecialMoveAnim) : 0) $ ","
                $ GetDoorAnimRatio(MyHero) $ ","
                $ GetDoorSyncId(MyHero) $ "," $ GetDoorSyncOpenRatio(MyHero);

            ConnectionLink.SendText(Packet $ "\n");
        }

        if (VoiceListener != None && VoiceListener.bClientConnected && Pawn != None && WorldInfo.TimeSeconds - LastVoiceControlSendTime > 0.05)
        {
            LastVoiceControlSendTime = WorldInfo.TimeSeconds;
            VoiceListener.SendControl(
                "POS,"
                $ Pawn.Location.X $ ","
                $ Pawn.Location.Y $ ","
                $ Pawn.Location.Z $ ","
                $ (Rotation.Yaw * (360.0 / 65536.0))
            );
            VoiceListener.SendControl("PTT," $ int(bMicTransmitting));
            if (Settings != None)
            {
                VoiceListener.SendControl("PROX," $ int(Settings.VoiceProximityNear) $ "," $ int(Settings.VoiceProximityFar));
                VoiceListener.SendControl("MUTE," $ int(Settings.bMuteEveryone || Settings.bMuteRemotePlayer) $ "," $ int(Settings.bMuteEveryone));
            }
        }
    }

    if (Pawn != None && Pawn != LastModeledPawn)
    {
        LastModeledPawn = Pawn;
        if (LocalModelIndex != 0)
            ApplyModelToHero(OLHero(Pawn), LocalModelIndex, true);
    }

    for (Idx = 0; Idx < RemotePlayers.Length; Idx++)
    {
        if (RemotePlayers[Idx].RemotePawn == None && Pawn != None)
        {
            RemotePlayers[Idx].RemotePawn = Spawn(class'OLTogetherRemoteHero',,, Pawn.Location, Pawn.Rotation,, true);
            if (RemotePlayers[Idx].RemotePawn != None)
            {
                RemotePlayers[Idx].RemoteCtrl = Spawn(class'OLTogetherRemoteControllerV2');
                if (RemotePlayers[Idx].RemoteCtrl != None)
                    RemotePlayers[Idx].RemoteCtrl.Possess(RemotePlayers[Idx].RemotePawn, false);
                RemoteHero = OLHero(RemotePlayers[Idx].RemotePawn);
                if (RemoteHero != None)
                {
                    MyHero = OLHero(Pawn);
                    if (MyHero != None && MyHero.CameraMesh != None && RemoteHero.CameraMeshShadowProxy != None)
                        RemoteHero.CameraMeshShadowProxy.SetSkeletalMesh(MyHero.CameraMesh.SkeletalMesh);
                    if (RemotePlayers[Idx].ModelIndex != 0)
                        ApplyModelToHero(RemoteHero, RemotePlayers[Idx].ModelIndex, false);
                }
            }
        }

        if (RemotePlayers[Idx].RemotePawn != None)
        {
            if (bHideLocalPawnDuringSpeedrun)
            {
                RemotePlayers[Idx].RemotePawn.SetHidden(true);
            }
            else if (ConnectionLink != None && ConnectionLink.bFadeNearbyPlayers)
            {
                GapToRemote = VSize(RemotePlayers[Idx].RemotePawn.Location - Pawn.Location);
                bFadeNow = (GapToRemote < ConnectionLink.NearbyFadeDistance);
                RemoteHero = OLHero(RemotePlayers[Idx].RemotePawn);
                if (!bFadeNow && RemoteHero != None && RemoteHero.ShadowProxy != None && RemoteHero.ShadowProxy.HiddenGame)
                    bFadeNow = (GapToRemote < ConnectionLink.NearbyFadeDistance + ConnectionLink.NearbyFadeHysteresis);
                if (RemoteHero != None)
                {
                    if (RemoteHero.ShadowProxy != None)
                        RemoteHero.ShadowProxy.SetHidden(bFadeNow);
                    if (RemoteHero.HeadMesh != None)
                        RemoteHero.HeadMesh.SetHidden(bFadeNow);
                    if (bFadeNow && RemoteHero.CameraMeshShadowProxy != None)
                        RemoteHero.CameraMeshShadowProxy.SetHidden(true);
                }
            }
        }
    }
}

exec function SetServerAddress(string NewIP)
{
    if (NewIP == "") return;
    ServerAddress = NewIP;
    if (ConnectionLink != None) ConnectionLink.SetServer(ServerAddress, ServerPort);
}

exec function SetServerPort(string NewPort)
{
    if (NewPort == "") return;
    ServerPort = NewPort;
    if (ConnectionLink != None) ConnectionLink.SetServer(ServerAddress, ServerPort);
}

exec function ConnectToServer()
{
    if (ConnectionLink != None) ConnectionLink.Reconnect();
}

exec function ToggleMouseSmoothing()
{
    if (PlayerInput != None)
    {
        PlayerInput.bEnableMouseSmoothing = !PlayerInput.bEnableMouseSmoothing;
        PlayerInput.SaveConfig();
        AddNotification(PlayerInput.bEnableMouseSmoothing ? "Mouse Smoothing: On" : "Mouse Smoothing: Off");
    }
}

exec function SetMouseSmoothing(bool bEnable)
{
    if (PlayerInput != None)
    {
        PlayerInput.bEnableMouseSmoothing = bEnable;
        PlayerInput.SaveConfig();
    }
}

function ApplySettings()
{
    if (Settings == None) return;
    if (PlayerInput != None) PlayerInput.SaveConfig();
    if (ConnectionLink != None) ConnectionLink.bFadeNearbyPlayers = Settings.bFadeNearbyPlayers;
}

Function LoadCheckpoint(string Checkpoint)
{
    StartNewGameAtCheckpoint(Checkpoint, false);
}

function SafeLoadCheckpoint(string Checkpoint)
{
    if (Checkpoint != "Admin_Gates") Checkpoint = "Admin_Gates";
    LoadCheckpoint(Checkpoint);
}

exec function ToggleSettingsMenu()
{
    local OLTogetherHUD H;
    if (bChatMode) return;
    H = OLTogetherHUD(HUD);
    if (H != None) { H.ToggleSettingsMenu(); bSettingsMenuOpen = H.bSettingsOpen; }
}

function bool IsSettingsMenuOpen()
{
    local OLTogetherHUD H;
    H = OLTogetherHUD(HUD);
    return H != None && H.bSettingsOpen;
}

function SettingsMenuClick()
{
    local OLTogetherHUD H;
    H = OLTogetherHUD(HUD);
    if (H != None) H.SettingsMenuClick(self);
}

function SettingsMenuInput(name Key)
{
    local OLTogetherHUD H;
    H = OLTogetherHUD(HUD);
    if (H == None) return;
    switch (Key)
    {
        case 'Up':    H.SettingsMoveSelection(-1); break;
        case 'Down':  H.SettingsMoveSelection(1);  break;
        case 'Left':  H.SettingsAdjust(self, -1);  break;
        case 'Right': H.SettingsAdjust(self, 1);   break;
        case 'PrevTab': H.CycleSettingsTab(-1); break;
        case 'NextTab': H.CycleSettingsTab(1); break;
        case 'Enter': H.SettingsAdjust(self, 0);   break;
        case 'Escape':
            H.CloseSettingsMenu();
            bSettingsMenuOpen = false;
            break;
    }
}

exec function ForceStartSpeedrun()
{
    if (!bSpeedrunMode || PlayerRole != 0) return;
    bPeerIsReady = true;
    bSpeedrunReady = true;
    BeginSpeedrunSequence();
    ToggleSettingsMenu();
}

exec function ToggleSpeedrunReady()
{
    if (!bSpeedrunMode || bSpeedrunSequenceActive) return;
    bSpeedrunReady = !bSpeedrunReady;
    if (bSpeedrunReady)
    {
        ConnectionLink.SendText("SRUN,READY\n");
        AddNotification("Ready - waiting for others...");
        if (bPeerIsReady) BeginSpeedrunSequence();
    }
    else ConnectionLink.SendText("SRUN,UNREADY\n");
}

function BeginSpeedrunSequence()
{
    local OLHero HeroRef;
    if (bSpeedrunSequenceActive || SpeedrunStartTime > 0.0) return;
    bSpeedrunSequenceActive = true;
    bSpeedrunCountdownActive = true;
    SpeedrunSequenceStartTime = WorldInfo.TimeSeconds;
    SpeedrunOverlayAlpha = 0.0;
    IgnoreMoveInput(true);
    IgnoreLookInput(true);
    bSpeedrunControlsLocked = true;
    HeroRef = OLHero(Pawn);
    if (HeroRef != None)
    {
        SpeedrunLockLocation = HeroRef.Location;
        SpeedrunLockRotation = HeroRef.Rotation;
    }
    AddNotification("Starting race...");
    if (PlayerRole == 0 && ConnectionLink != None) ConnectionLink.SendText("SRUN,SEQ\n");
    SafeLoadCheckpoint("Admin_Gates");
    SetTimer(3.0, false, 'SpeedrunSequenceTeleport');
}

function SpeedrunSequenceTeleport()
{
    HideSpeedrunPawn();
    if (PlayerRole == 0 && ConnectionLink != None) ConnectionLink.SendText("SRUN,TP\n");
    SetTimer(1.5, false, 'SpeedrunSequenceStartCountdown');
}

function SpeedrunSequenceStartCountdown()
{
    bSpeedrunControlsLocked = false;
    IgnoreMoveInput(true);
    IgnoreLookInput(true);
    bSpeedrunControlsLocked = true;
    BeginSpeedrunCountdown('SpeedrunCountdownTick');
}

function SpeedrunCountdownTick()
{
    CountDownTickCommon('SpeedrunCountdownTick');
}

function BeginSpeedrunSequenceClient()
{
    local OLHero HeroRef;
    if (bSpeedrunSequenceActive) return;
    bSpeedrunSequenceActive = true;
    bSpeedrunCountdownActive = true;
    SpeedrunSequenceStartTime = WorldInfo.TimeSeconds;
    SpeedrunOverlayAlpha = 0.0;
    IgnoreMoveInput(true);
    IgnoreLookInput(true);
    bSpeedrunControlsLocked = true;
    if (RemotePlayers.Length > 0 && RemotePlayers[0].RemotePawn != None)
        HeroRef = OLHero(RemotePlayers[0].RemotePawn);
    if (HeroRef != None)
    {
        SpeedrunLockLocation = HeroRef.Location;
        SpeedrunLockRotation = HeroRef.Rotation;
    }
    AddNotification("Starting race...");
}

function SpeedrunSequenceTeleportClient()
{
    HideSpeedrunPawn();
    SetTimer(1.5, false, 'SpeedrunSequenceStartCountdownClient');
}

function SpeedrunSequenceStartCountdownClient()
{
    BeginSpeedrunCountdown('SpeedrunCountdownTickClient');
}

function SpeedrunCountdownTickClient()
{
    CountDownTickCommon('SpeedrunCountdownTickClient');
}

function SpeedrunRemoteGo()
{
    ClearTimer('SpeedrunCountdownTickClient');
    bSpeedrunCountdownActive = false;
    bSpeedrunSequenceActive = false;
    SpeedrunStartTime = WorldInfo.TimeSeconds;
    SpeedrunCountdownStartTime = 0.0;
    ResetSpeedrunState();
    ShowSpeedrunPawn();
    AddNotification("GO!");
}

function CheckSpeedrunCheckpoint(name CheckpointName)
{
    local string Label;
    local float FT;
    if (!bSpeedrunMode || bSpeedrunSequenceActive || SpeedrunStartTime == 0.0) return;
    Label = string(CheckpointName);
    if (Label == "Lab_BigStairDone" && SpeedrunFinishTime == 0.0)
    {
        FT = WorldInfo.TimeSeconds - SpeedrunStartTime;
        SpeedrunFinishTime = FT;
        AddNotification("Finished! Time: " $ int(FT) $ "." $ int((FT % 1.0) * 100));
    }
}

exec function SetLocalPlayerName(string NewName)
{
    if (NewName == "") return;
    LocalPlayerName = NewName;
    bPlayerNameAnnounced = false;
    LastSentPlayerName = "";
    if (ConnectionLink != None && ConnectionLink.bIsConnected)
        ConnectionLink.SendText("NAME," $ LocalPlayerName $ "\n");
}

exec function Chat(string Message)
{
    if (Message == "") return;
    if (ConnectionLink != None && ConnectionLink.bIsConnected)
    {
        ConnectionLink.SendText("CHAT," $ LocalPlayerName $ ": " $ Message $ "\n");
        AddChatLine("You: " $ Message);
    }
    else AddChatLine("Chat failed - not connected.");
}

function AddChatLine(string Msg)
{
    local OLTogetherHUD H;
    if (Msg == "") return;
    H = OLTogetherHUD(HUD);
    if (H != None) H.AddChatLine(Msg);
}

function AddNotification(string Msg)
{
    local OLTogetherHUD H;
    if (Msg == "") return;
    H = OLTogetherHUD(HUD);
    if (H != None) H.AddNotification(Msg);
}

function OnReceiveData(string Data)
{
    local array<string> F;
    local vector IL, IV;
    local rotator IR;
    local bool BC, CC, bRunning, bPlayingAnim;
    local int CS, LM, SM, DD, LD, ED, ET, HP, FromCid, RIdx;
    local float SMs, NMs, TS, DoorRatio, DoorSyncOpenRatio;
    local int DoorSyncId;
    local OLTogetherRemoteControllerV2 RemoteV2;

    RIdx = -1;

    if (Left(Data, 9) == "YOUR_CID,")
    {
        MyPlayerCid = int(Right(Data, Len(Data) - 9));
        `log("[OLTogether] YOUR_CID=" $ MyPlayerCid);
        return;
    }

    if (Left(Data, 5) == "FROM,")
    {
        F = SplitString(Data, ",", true);
        if (F.Length < 3) return;
        FromCid = int(F[1]);
        Data = Right(Data, Len(Data) - (Len(F[0]) + Len(F[1]) + 2));
        RIdx = FindOrCreateRemote(FromCid);
    }

    if (Left(Data, 5) == "CHAT,") { AddChatLine(Right(Data, Len(Data) - 5)); return; }

    if (Left(Data, 6) == "MODEL,")
    {
        F = SplitString(Data, ",", true);
        if (F.Length >= 2 && RIdx >= 0 && RemotePlayers[RIdx].RemotePawn != None)
        {
            RemotePlayers[RIdx].ModelIndex = int(F[1]);
            ApplyModelToHero(OLHero(RemotePlayers[RIdx].RemotePawn), RemotePlayers[RIdx].ModelIndex, false);
        }
        return;
    }

    if (Left(Data, 5) == "NAME,")
    {
        if (RIdx >= 0)
        {
            RemotePlayers[RIdx].PlayerName = Right(Data, Len(Data) - 5);
            if (RemotePlayers[RIdx].PlayerName == "")
                RemotePlayers[RIdx].PlayerName = "Player";
        }
        return;
    }

    if (Left(Data, 5) == "PONG,")
    {
        F = SplitString(Data, ",", true);
        if (F.Length >= 2)
        {
            SMs = float(F[1]);
            NMs = WorldInfo.TimeSeconds * 1000.0;
            RoundTripPingMs = int(NMs - SMs);
        }
        return;
    }

    if (Left(Data, 6) == "NOTIF,") { AddNotification(Right(Data, Len(Data) - 6)); return; }
    if (Left(Data, 5) == "SRUN,") { HandleSpeedrunPacket(Data); return; }

    if (Left(Data, 5) == "TALK,")
    {
        F = SplitString(Data, ",", true);
        if (F.Length >= 2 && RIdx >= 0)
        {
            if (int(F[1]) != 0)
                RemotePlayers[RIdx].bTalking = !(Settings != None && Settings.bMuteRemotePlayer);
            else
                RemotePlayers[RIdx].bTalking = false;
        }
        return;
    }

    if (Left(Data, 10) == "SPECIAL_S,")
    {
        F = SplitString(Data, ",", true);
        if (F.Length >= 3 && RIdx >= 0 && RemotePlayers[RIdx].RemoteCtrl != None)
        {
            RemoteV2 = OLTogetherRemoteControllerV2(RemotePlayers[RIdx].RemoteCtrl);
            if (RemoteV2 != None)
                RemoteV2.SetRemoteSpecialStart(int(F[1]), int(F[2]) != 0);
        }
        return;
    }

    if (Left(Data, 9) == "SPECIAL_E")
    {
        // Ignored - SM transitions are handled by LOC packets now
        return;
    }

    // Handle legacy full-state packets (LOC,...) - delta encoding disabled for now due to UnrealScript limitations
    if (Left(Data, 4) != "LOC,") return;
    if (RIdx < 0) return;

    F = SplitString(Data, ",", true);
    if (F.Length < 18 || F[0] != "LOC") return;

    TS = float(F[1]);
    IL.X = float(F[2]); IL.Y = float(F[3]); IL.Z = float(F[4]);
    IR.Pitch = int(F[5]); IR.Yaw = int(F[6]); IR.Roll = 0;
    IV.X = float(F[7]); IV.Y = float(F[8]); IV.Z = float(F[9]);
    CC = int(F[10]) != 0; BC = int(F[11]) != 0; CS = int(F[12]);
    LM = int(F[13]); SM = int(F[14]); DD = int(F[15]);
    LD = (F.Length >= 17) ? int(F[16]) : 0;
    ED = (F.Length >= 18) ? int(F[17]) : 0;
    ET = (F.Length >= 19) ? int(F[18]) : 0;
    HP = (F.Length >= 20) ? int(F[19]) : 100;
    bRunning = (F.Length >= 21) ? int(F[20]) != 0 : VSize(IV) > 300.0;
    bPlayingAnim = (F.Length >= 22) ? int(F[21]) != 0 : false;
    DoorRatio = (F.Length >= 23) ? float(F[22]) : 0.0;

    // Door sync fields (fields 23, 24)
    DoorSyncId = (F.Length >= 24) ? int(F[23]) : 0;
    DoorSyncOpenRatio = (F.Length >= 25) ? float(F[24]) : -1.0;

    RemotePlayers[RIdx].Health = HP;

    if (RemotePlayers[RIdx].RemoteCtrl != None)
    {
        RemoteV2 = OLTogetherRemoteControllerV2(RemotePlayers[RIdx].RemoteCtrl);
        if (RemoteV2 != None)
        {
            RemoteV2.AddState(TS, IL, IR, IV, CC, BC, CS, LM, SM, DD, LD, ED, ET, HP, bRunning, bPlayingAnim, DoorRatio);
            RemoteV2.SyncDoorState(DoorSyncId, DoorSyncOpenRatio);
        }
    }
}

function HandleSpeedrunPacket(string Data)
{
    local array<string> F;
    F = SplitString(Data, ",", true);
    if (F.Length < 2) return;
    if (F[1] == "READY") { bPeerIsReady = true; if (bSpeedrunReady && !bSpeedrunSequenceActive) BeginSpeedrunSequence(); }
    else if (F[1] == "UNREADY") bPeerIsReady = false;
    else if (F[1] == "SEQ")  BeginSpeedrunSequenceClient();
    else if (F[1] == "TP")   SpeedrunSequenceTeleportClient();
    else if (F[1] == "GO")   SpeedrunRemoteGo();
}

DefaultProperties
{
    InputClass=class'OLTogetherInput'
    bSpeedrunSequenceActive=false
    bSpeedrunControlsLocked=false
    bHideLocalPawnDuringSpeedrun=false
    SpeedrunOverlayAlpha=0.0
    SpeedrunOverlayPulse=0.0
    LocalModelIndex=0
    bModelAnnounced=false
    LastSentModelIndex=-1
    LastModelSendTime=-999.0
    LastSentSpecialMove=0
    MyPlayerCid=0
    IdleStateSendInterval=0.25
    ActiveStateSendInterval=0.033
}
