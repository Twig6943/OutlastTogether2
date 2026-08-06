// High-performance remote controller with adaptive interpolation and predictive dead reckoning
class OLTogetherRemoteControllerV2 extends AIController;

var OLTogetherRemoteHero RemoteHero;
var OLTogetherNetworkState NetworkState;

// Interpolation state
var float TeleportDistThreshold;
var float InterpSpeed;
var bool bHasState;

// Current rendered state
var int CurrentLocomotionMode;
var int CurrentSpecialMove;
var int CurrentDoorDir;
var int CurrentLeanDir;
var bool bCurrentLeftAnim;     // Left/right anim variant from host (via ExtraData)
var int CurrentExtraData;
var int CurrentExtraKind;
var bool bCurrentCrouched;
var bool bCurrentCamcorder;
var int CurrentCamcorderState;
var int CurrentHealth;

// Special move animation state
var bool bPlayingSpecialAnim;
var bool bPositionLocked;  // Whether position is locked during this animation
var bool bLockRotation;    // Whether rotation is locked during this animation (false = let anim drive it)
var float SpecialAnimStartTime;
var float SpecialAnimDuration;
var vector VaultLockStartPos;
var vector VaultLockFwd;
var rotator VaultLockRot;
var int LastPlayedSpecialMove;

// Door animation tracking
var bool bDoorAnimFlipped;  // True when rotation is flipped 180 for door entry anim

// Vault approach handling
var bool bWaitingForInstantVault;
var int PendingVaultMoveType;
var bool bPendingVaultRunning;
var float InstantVaultDelayTime;
var bool bLedgeIdleStarted;  // Track if ledge idle was started early during grab anim
var bool bBedIdleStarted;    // Track if bed idle was started early during enter bed anim

// Crouch transition tracking
var bool bPlayingCrouchTransition;
var float CrouchTransitionStartTime;
var float CrouchTransitionDuration;
var float AnimLockEndTime;  // From original: prevents idle system from overriding transition
var name LastMovementAnim;  // From original: tracks current movement anim to avoid redundant swaps

// Cutscene animation tracking
var int CurrentCutsceneAnim;  // ID of the current cutscene animation
var bool bPlayingCutscene;    // Whether a cutscene animation is currently playing
var rotator MeshRotation;     // Pawn body rotation (separate from camera rotation)
var rotator DesiredMeshRotation; // Target mesh rotation from network

// SM re-trigger prevention
var int LastEndedSpecialMove;
var float LastSpecialMoveEndTime;

// Door sync state
var int SyncDoorId;           // Hash of host's active door location
var float SyncDoorOpenRatio;  // Host's active door open ratio (-1 = no door)
var int SyncDoorBreakState;   // Host's door break state (0=Normal, 1=Breaking, 2=Broken)
var OLDoor SyncedDoor;        // Cached reference to the synced door
var float SyncedDoorOpenRatio; // Current interpolated open ratio

// Prediction state
var vector PredictedLocation;
var int PredictedYaw;
var int LastReceivedYaw;
var float LastStateUpdateTime;

// Map cutscene animation ID to animation name
function name GetCutsceneAnimName(int CutsceneID)
{
    switch (CutsceneID)
    {
        case 1: return 'SE_AdminBlock_IntroMiles_p1_hero';
        case 2: return 'SE_AdminBlock_IntroMiles_p2_hero';
        case 3: return 'SE_AdminBlock_PriestDrugsMiles_hero';
        case 4: return 'SE_AdminBlockRv_AirventPushCorpse_hero';
        case 5: return 'SE_Miles_PriestIntro_01';
        case 6: return 'SE_Miles_PriestIntro_OnTheFloor_01';
        case 7: return 'SE_Miles_PriestIntro_StandingUp_01';
        case 8: return 'SE_PatientAttack_Player';
        case 9: return 'SE_Prison_CellGrabber_hero';
        case 10: return 'SE_SqueezeThrow_Player';
        case 11: return 'SE_SecurityRoom_SitDown_Player';
        case 12: return 'SE_SecurityRoom_WaitCycle_Player';
        case 13: return 'SE_SecurityRoom_GetUp_Player';
        case 14: return 'SE_AdminBlock_IntroMiles_p2_handycam';
        case 15: return 'SE_AdminBlock_PriestDrugsMiles_handycam';
        case 16: return 'SE_Prison_MilesWakeUp';
        case 17: return 'SE_Prison_Miles_SASExplosion';
        case 18: return 'SE_Prison_CellGrabber_V2_hero';
        case 19: return 'SE_MaleWard_Torture_p1_hero';
        case 20: return 'SE_MaleWard_Torture_p2_hero';
        case 21: return 'SE_MaleWard_Torture_p3_hero';
        case 22: return 'SE_MaleWard_Torture_p4_hero';
        case 23: return 'SE_MaleWard_Torture_p5_hero';
        case 24: return 'SE_MaleWard_Torture_p6_hero_end';
        case 25: return 'SE_MaleWard_Torture_p6_hero_struggleCYCLE';
        case 26: return 'SE_MaleWard_Torture_p6_hero_struggleENTER';
        case 27: return 'SE_MaleWard_Torture_p6_hero_struggleEXIT';
        case 28: return 'SE_MaleWard_ElevatorFight_p2_hero';
        case 29: return 'SE_PyroStruggle_player_enter';
        case 30: return 'SE_PyroStruggle_player_exit';
        case 31: return 'SE_PyroStruggle_player_loop';
        case 32: return 'SE_PyroStruggle_player_fail';
        case 33: return 'SE_PyroStruggle_V2_hero';
        case 34: return 'SE_ReceptionHall_Rise_Player';
        case 35: return 'SE_SecurityRoom_Ending_Player';
        case 36: return 'SE_PatientSurpriseAttack_hero_cycle';
        case 37: return 'SE_PatientSurpriseAttack_hero_entry';
        case 38: return 'SE_PatientSurpriseAttack_hero_exit';
        case 39: return 'Player_End';
        case 40: return 'SE_Prison_CellGrabber_Struggle_player_cycle';
        case 41: return 'SE_Prison_CellGrabber_Struggle_player_entry';
        case 42: return 'SE_Prison_CellGrabber_Struggle_player_exit';
        case 43: return 'SE_FemaleWard_Fall_hero';
        case 44: return 'SE_Prison_CellGrabber_Struggle_player_fail';
        case 45: return 'SE_PatientSurpriseAttack_player_fail';
        case 46: return 'SE_PatientSurpriseAttack_V2_hero';
        case 47: return 'SE_FemaleWard_BumpInTheDark_Player';
        case 48: return 'SE_SwarmKillsSoldier_hero';
        case 49: return 'SE_Lab_SwarmThrowDown';
        case 50: return 'SE_Lab_FinaleV2_p1_hero_old';
        case 51: return 'SE_Lab_FinaleV2_p2_hero_Death';
        case 52: return 'SE_Lab_FinaleV3_p1_hero';
        case 53: return 'SE_Lab_FinaleV3_1stStumble_hero';
        case 54: return 'SE_Lab_FinaleV3_2ndStumble_hero';
        case 55: return 'SE_Lab_FinaleV3_3rdStumble_hero';
        default: return 'None';
    }
}

// Play cutscene animation on remote hero
function PlayCutsceneAnimation(int CutsceneID)
{
    local name AnimName;
    
    if (RemoteHero == None || RemoteHero.ShadowProxyFullBodyAnimSlot == None)
        return;
    
    AnimName = GetCutsceneAnimName(CutsceneID);
    if (AnimName == 'None')
    {
        `log("[CUTSCENE_ERROR] Unknown cutscene ID:" @ CutsceneID);
        return;
    }
    
    `log("[CUTSCENE_PLAY] Playing cutscene animation:" @ AnimName @ "ID:" @ CutsceneID @ "Time:" @ WorldInfo.TimeSeconds);
    
    // Play the cutscene animation (non-looping, controlled by Matinee timeline on host)
    RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim(AnimName, 1.0, 0.1, 0.1, false, false);
    bPlayingCutscene = true;
}

// Set mesh rotation from network (body rotation, separate from camera rotation)
function SetMeshRotation(rotator NewMeshRotation)
{
    DesiredMeshRotation = NewMeshRotation;
    DesiredMeshRotation.Pitch = 0;
    DesiredMeshRotation.Roll = 0;
}

function Possess(Pawn inPawn, bool bVehicleTransition)
{
    super.Possess(inPawn, bVehicleTransition);
    RemoteHero = OLTogetherRemoteHero(inPawn);
    if (RemoteHero != None)
    {
        RemoteHero.SetMovementPhysics();
        RemoteHero.Controller = self;
        InitRemoteVisibility();
    }
    
    NetworkState = new class'OLTogetherNetworkState';
}

function InitRemoteVisibility()
{
    if (RemoteHero == None) return;
    if (RemoteHero.Mesh != None)
    {
        RemoteHero.Mesh.SetHidden(true);
        RemoteHero.Mesh.SetOwnerNoSee(true);
        RemoteHero.Mesh.bUpdateSkelWhenNotRendered = false;   // Don't tick hidden mesh
        RemoteHero.Mesh.bTickAnimNodesWhenNotRendered = false; // Stop anim tree from ticking on hidden mesh - prevents SyncShadowProxy from overwriting our custom anims
        RemoteHero.Mesh.RootMotionMode = RMM_Ignore;
    }
    if (RemoteHero.ShadowProxy != None)
    {
        RemoteHero.ShadowProxy.SetOwnerNoSee(false);
        RemoteHero.ShadowProxy.SetHidden(false);
        RemoteHero.ShadowProxy.bUpdateSkelWhenNotRendered = true;
        RemoteHero.ShadowProxy.bTickAnimNodesWhenNotRendered = true;
        RemoteHero.ShadowProxy.RootMotionMode = RMM_Ignore;
    }
    if (RemoteHero.HeadMesh != None)
    {
        RemoteHero.HeadMesh.SetHidden(false);
        RemoteHero.HeadMesh.SetOwnerNoSee(false);
    }
    if (RemoteHero.CameraMeshShadowProxy != None)
        RemoteHero.CameraMeshShadowProxy.SetHidden(true);
    RemoteHero.SetPhysics(PHYS_None);
    RemoteHero.SetCollisionType(COLLIDE_NoCollision);
    RemoteHero.bCollideWorld = false;
    RemoteHero.bBlockActors = false;
}

function UnPossess()
{
    RemoteHero = None;
    super.UnPossess();
}

// Receive network state update
function AddState(float TimeStamp, vector NewLocation, rotator NewRotation, vector NewVelocity,
    bool bNewCrouched, bool bNewCamcorder, int NewCamState,
    int NewLocomotionMode, int NewSpecialMove,
    int NewDoorDir, int NewLeanDir, int NewExtraData, int NewExtraKind, int NewHealth,
    bool bNewRunning, bool bNewPlayingAnim, float NewDoorRatio)
{
    local OLTogetherNetworkState.CompactState NewState;
    
    if (NetworkState == None)
        return;
    
    // Pack state into compact format
    NewState.TimeStamp = TimeStamp;
    NewState.Location = NewLocation;
    NewState.Velocity = NewVelocity;
    NewState.Yaw = NewRotation.Yaw;
    
    // Pack boolean flags into single byte
    NewState.PackedFlags = 0;
    if (bNewCrouched) NewState.PackedFlags = NewState.PackedFlags | 1;
    if (bNewCamcorder) NewState.PackedFlags = NewState.PackedFlags | 2;
    if (bNewRunning) NewState.PackedFlags = NewState.PackedFlags | 4;
    if (bNewPlayingAnim) NewState.PackedFlags = NewState.PackedFlags | 8;
    
    NewState.LocomotionMode = NewLocomotionMode;
    NewState.SpecialMove = NewSpecialMove;
    NewState.CamcorderState = NewCamState;
    NewState.Health = NewHealth;
    NewState.DoorDir = NewDoorDir;
    NewState.LeanDir = NewLeanDir;
    NewState.ExtraData = NewExtraData;
    NewState.ExtraKind = NewExtraKind;
    NewState.DoorRatio = NewDoorRatio;
    
    // Add to buffer
    NetworkState.StateBuffer.AddItem(NewState);
    
    // Trim old states (keep last 2 seconds worth at 30Hz = 60 states)
    if (NetworkState.StateBuffer.Length > 60)
        NetworkState.StateBuffer.Remove(0, NetworkState.StateBuffer.Length - 60);
    
    // Update jitter metrics for adaptive delay
    NetworkState.UpdateJitterMetrics(WorldInfo.TimeSeconds);
    
    // Update server time offset
    NetworkState.ServerTimeOffset = TimeStamp - WorldInfo.TimeSeconds;
    NetworkState.bHasReceivedState = true;
    bHasState = true;
    
    // Initialize prediction position on first state
    if (!NetworkState.bHasReceivedState)
    {
        PredictedLocation = NewLocation;
        PredictedYaw = NewRotation.Yaw;
    }
    
    LastReceivedYaw = NewRotation.Yaw;
    LastStateUpdateTime = WorldInfo.TimeSeconds;
    NetworkState.LastReceivedState = NewState;
}

function float GetHostTime()
{
    if (NetworkState == None)
        return WorldInfo.TimeSeconds;
    return WorldInfo.TimeSeconds + NetworkState.ServerTimeOffset;
}

// Find two states to interpolate between using adaptive delay
function bool FindBracketingStates(float ReqTime, out OLTogetherNetworkState.CompactState OutBefore, 
    out OLTogetherNetworkState.CompactState OutAfter, out float OutAlpha)
{
    local int Idx;
    
    if (NetworkState == None || NetworkState.StateBuffer.Length == 0)
        return false;
    
    // Search backwards for the state just before our render time
    for (Idx = NetworkState.StateBuffer.Length - 1; Idx >= 0; Idx--)
    {
        if (NetworkState.StateBuffer[Idx].TimeStamp <= ReqTime)
        {
            OutBefore = NetworkState.StateBuffer[Idx];
            
            // If we have a next state, interpolate between them
            if (Idx < NetworkState.StateBuffer.Length - 1)
            {
                OutAfter = NetworkState.StateBuffer[Idx + 1];
                OutAlpha = (ReqTime - OutBefore.TimeStamp) / FMax(OutAfter.TimeStamp - OutBefore.TimeStamp, 0.0001);
                OutAlpha = FClamp(OutAlpha, 0.0, 1.0);
            }
            else
            {
                // No future state yet - extrapolate using prediction
                OutAfter = NetworkState.PredictState(OutBefore, ReqTime - OutBefore.TimeStamp);
                OutAlpha = 1.0;
            }
            return true;
        }
    }
    
    // All states are in the future - use earliest one
    OutBefore = NetworkState.StateBuffer[0];
    OutAfter = NetworkState.StateBuffer[0];
    OutAlpha = 0.0;
    return true;
}

function PlaySpecialMoveAnim(int MoveType, bool bRunning)
{
    local name AnimName;
    local float AnimDuration, BlendIn, BlendOut;
    local vector Fwd;
    local int DoorDir;
    local bool bIsLeft, bIsPush;
    
    if (RemoteHero == None) return;
    if (RemoteHero.ShadowProxyFullBodyAnimSlot == None) return;
    
    `log("[PLAY_SM] MoveType:" @ MoveType @ "bPlayingBefore:" @ bPlayingSpecialAnim @ "CurrentSM:" @ CurrentSpecialMove @ "LM:" @ CurrentLocomotionMode @ "bCrouched:" @ bCurrentCrouched @ "bLeftAnim:" @ bCurrentLeftAnim @ "SlotAnim:" @ RemoteHero.ShadowProxyFullBodyAnimSlot.GetPlayedAnimation() @ "Time:" @ WorldInfo.TimeSeconds);
    
    if (bPlayingSpecialAnim)
        EndSpecialMoveAnim();
    
    // Default blend times (from OLHero::PlayFullBodyAnim)
    BlendIn = 0.25;
    BlendOut = 0.25;
    AnimDuration = 1.0;
    bPositionLocked = false;
    bLockRotation = true;
    bLedgeIdleStarted = false;
    bBedIdleStarted = false;
    DoorDir = CurrentDoorDir;
    
    switch (MoveType)
    {
        // Crouch/Uncrouch (cases 1,2) handled separately by crouch state handler - skip here
        
        // === JUMPS ===
        // Original only uses jump_on_spot for case 3 - no run/walk variant
        case 3:  // SMT_JumpOnSpot
            AnimName = 'player_jump_on_spot';
            AnimDuration = 1.25;
            BlendIn = 0.15;
            BlendOut = 0.25;
            break;
            
        // From OLHero.cpp line 538-541: BlendIn=0.1, BlendOut=0.25
        case 4:  // SMT_BigLanding
            AnimName = 'player_landing_big';
            AnimDuration = 2.29;
            BlendIn = 0.1;
            BlendOut = 0.25;
            break;
            
        // === VAULTS ===
        // From OLHero.cpp line 544-553: BlendIn=0.1, BlendOut=0.25
        case 5:  // SMT_JumpOver
            AnimName = bRunning ? 'player_jump_over_from_run' : 'player_jump_over_from_walk';
            AnimDuration = 1.25;
            BlendIn = 0.1;
            BlendOut = 0.25;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            bPositionLocked = true;
            break;
            
        // From OLHero.cpp line 664-666: BlendIn=0.1, BlendOut=0.25
        case 6:  // SMT_JumpOverAndGrabLedge
            AnimName = 'player_jump_over_to_ledge';
            AnimDuration = 2.29;
            BlendIn = 0.1;
            BlendOut = 0.25;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            bPositionLocked = true;
            break;
            
        // === SLIDE ===
        // From OLHero.cpp line 582-586: BlendIn=0.3, BlendOut=0.35
        case 7:  // SMT_SlideOver
            AnimName = 'player_slide_over_from_run';
            AnimDuration = 1.25;
            BlendIn = 0.3;
            BlendOut = 0.35;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            bPositionLocked = true;
            break;
            
        // === CLIMB ===
        // From OLHero.cpp line 561-574: BlendIn=0.1, BlendOut=0.25
        case 8:  // SMT_ClimbUpObstacle
            AnimName = bRunning ? 'player_climb_up_from_run' : 'player_climb_up_from_walk';
            AnimDuration = bRunning ? 1.04 : 1.21;
            BlendIn = 0.1;
            BlendOut = 0.25;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            bPositionLocked = true;
            break;
            
        // === LEDGE ANIMATIONS ===
        // From OLHero.cpp PlayFullBodyAnim calls for ledge SMs
        
        case 14: // SMT_GrabLedgeFromGround
            // From OLHero.cpp line 649-652: PlayBlendedAnim(High, Low, alpha, 0.25, 0.25)
            AnimName = 'player_jump_to_ledge_from_walk';
            AnimDuration = 1.5;  // Buffer for locomotion transition to LM_LedgeHang
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            bPositionLocked = true;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            break;
            
        case 15: // SMT_GrabLedgeFromAir
            // From OLHero.cpp line 654-657: BlendIn=0.1, BlendOut=0.25
            AnimName = 'player_grab_ledge_from_air';
            AnimDuration = 1.04;
            BlendIn = 0.1;
            BlendOut = 0.25;
            bPositionLocked = true;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            break;
            
        case 16: // SMT_LedgeHangTransition
            // From OLHero.cpp line 589-613: multiple variants, BlendIn=0.1, BlendOut=0.1
            // ELedgeTransitionType: 0=LeftInside, 1=LeftOutside, 2=RightInside, 3=RightOutside
            switch (CurrentDoorDir)
            {
                case 0:  AnimName = 'player_ledge_move_left'; break;
                case 1:  AnimName = 'player_ledge_move_left_90_outside'; break;
                case 2:  AnimName = 'player_ledge_move_right'; break;
                case 3:  AnimName = 'player_ledge_move_right_90_outside'; break;
                default: AnimName = 'player_ledge_move_left'; break;
            }
            AnimDuration = 1.25;
            BlendIn = 0.1;
            BlendOut = 0.1;
            bPositionLocked = true;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            break;
            
        case 17: // SMT_ClimbUpLedge
            // From OLHero.cpp line 616-647: multiple variants
            // Default to climb up to stand: BlendIn=0.1, BlendOut=0.5
            AnimName = 'player_climb_ledge_to_stand';
            AnimDuration = 1.67;
            BlendIn = 0.1;
            BlendOut = 0.5;
            bPositionLocked = true;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            break;
            
        case 18: // SMT_DropFromLedge
            // Hero just drops - no specific anim in C++, just releases ledge
            // Play a brief release/falling animation
            AnimName = 'player_falling_loop';
            AnimDuration = 1.0;
            BlendIn = 0.1;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        case 19: // SMT_GrabAndClimb
            // From OLHero.cpp line 659-662: BlendIn=0.1, BlendOut=0.25
            AnimName = 'player_grab_ledge_from_air';
            AnimDuration = 1.04;
            BlendIn = 0.1;
            BlendOut = 0.25;
            bPositionLocked = true;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            break;
            
        case 20: // SMT_EnterLedgeWalk
            // From OLHero.cpp line 669-696: multiple variants, BlendIn=0.1, BlendOut=0.1
            // ELedgeTransitionType: 0=LeftInside, 1=LeftOutside, 2=RightInside, 3=RightOutside
            switch (CurrentDoorDir)
            {
                case 0:  AnimName = 'player_ledge_walk_enter_left_inside_perp'; break;
                case 1:  AnimName = 'player_ledge_walk_enter_left_outside_perp'; break;
                case 2:  AnimName = 'player_ledge_walk_enter_right_inside_perp'; break;
                case 3:  AnimName = 'player_ledge_walk_enter_right_outside_perp'; break;
                default: AnimName = 'player_ledge_walk_enter_left_inside_perp'; break;
            }
            AnimDuration = 2.13;
            BlendIn = 0.1;
            BlendOut = 0.1;
            bPositionLocked = false;
            break;
            
        case 21: // SMT_ExitLedgeWalk
            // From OLHero.cpp line 698-724: multiple variants, BlendIn=0.25, BlendOut=0.5
            // ELedgeTransitionType: 0=LeftInside, 1=LeftOutside, 2=RightInside, 3=RightOutside
            switch (CurrentDoorDir)
            {
                case 0:  AnimName = 'player_ledge_walk_exit_left'; break;
                case 1:  AnimName = 'player_ledge_walk_exit_left_outside_left'; break;
                case 2:  AnimName = 'player_ledge_walk_exit_right'; break;
                case 3:  AnimName = 'player_ledge_walk_exit_right_outside_right'; break;
                default: AnimName = 'player_ledge_walk_exit_left'; break;
            }
            AnimDuration = 2.29;
            BlendIn = 0.25;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        case 22: // SMT_LedgeWalkTransition
            // From OLHero.cpp line 725-747: multiple variants, BlendIn=0.1, BlendOut=0.1
            // ELedgeTransitionType: 0=LeftInside, 1=LeftOutside, 2=RightInside, 3=RightOutside
            switch (CurrentDoorDir)
            {
                case 0:  AnimName = 'player_ledge_walk_transition_left_90_inside'; AnimDuration = 1.83; break;
                case 1:  AnimName = 'player_ledge_walk_transition_left_90_outside'; AnimDuration = 1.75; break;
                case 2:  AnimName = 'player_ledge_walk_transition_right_90_inside'; AnimDuration = 1.83; break;
                case 3:  AnimName = 'player_ledge_walk_transition_right_90_outside'; AnimDuration = 1.75; break;
                default: AnimName = 'player_ledge_walk_transition_left_90_inside'; AnimDuration = 1.83; break;
            }
            AnimDuration = 1.83;
            BlendIn = 0.1;
            BlendOut = 0.1;
            bPositionLocked = false;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            break;
            
        case 23: // SMT_JumpFromLedgeWalk
            // From OLHero.cpp line 752-756: BlendIn=0.1, BlendOut=0.15
            AnimName = 'player_jump_from_ledge_walk';
            AnimDuration = 0.25;
            BlendIn = 0.1;
            BlendOut = 0.15;
            bPositionLocked = true;
            VaultLockStartPos = RemoteHero.Location;
            VaultLockRot = RemoteHero.Rotation;
            Fwd = vector(VaultLockRot);
            Fwd.Z = 0;
            if (VSize(Fwd) > 0.0)
                VaultLockFwd = Normal(Fwd);
            else
                VaultLockFwd = vect(1,0,0);
            break;
            
        // === DOOR INTERACTIONS ===
        // From OLHero.cpp line 950-990: BlendIn=0.25, BlendOut=0.25
        
        case 28: // SMT_EnterDoorInteraction
            // Use interact_push/pull animations (4.17s), NOT access animations (0.83s entry)
            // DOT_LeftPush=0, DOT_LeftPull=1, DOT_RightPush=2, DOT_RightPull=3
            bIsLeft = (DoorDir == 0 || DoorDir == 1);
            bIsPush = (DoorDir == 0 || DoorDir == 2);
            if (bIsPush && SyncedDoor != None && SyncedDoor.bReverseDirection)
                bIsLeft = !bIsLeft;
            if (bIsPush)
                AnimName = bIsLeft ? 'player_door_interact_push_left' : 'player_door_interact_push_right';
            else
                AnimName = bIsLeft ? 'player_door_open_inside_left' : 'player_door_open_inside_right';
            `log("[DOOR_REMOTE] SM:28 DoorDir:" @ DoorDir @ "bIsLeft:" @ bIsLeft @ "bIsPush:" @ bIsPush @ "Anim:" @ AnimName @ "SyncedDoor:" @ SyncedDoor @ "Time:" @ WorldInfo.TimeSeconds);
            AnimDuration = 4.17;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            // Setup ShadowProxyDoorAnimNode like OLHero.cpp line 7182
            if (RemoteHero.ShadowProxyDoorAnimNode != None)
            {
                RemoteHero.ShadowProxyDoorAnimNode.SetActiveChild(DoorDir, 0.0);
                RemoteHero.ShadowProxyDoorAnimNode.PlayRate = 0.5;
                RemoteHero.ShadowProxyDoorAnimNode.MaxRatio = 1.0;
                RemoteHero.ShadowProxyDoorAnimNode.CurrentRatio = 0.0;
            }
            break;
            
        case 29: // SMT_OpenDoorInstant
            // Don't lock position - let interpolation handle it
            bIsLeft = (DoorDir == 0 || DoorDir == 1);
            bIsPush = (DoorDir == 0 || DoorDir == 2);
            if (bIsPush && SyncedDoor != None && SyncedDoor.bReverseDirection)
                bIsLeft = !bIsLeft;
            if (bIsPush)
                AnimName = bIsLeft ? 'player_door_open_push_left' : 'player_door_open_push_right';
            else
                AnimName = bIsLeft ? 'player_door_open_inside_left' : 'player_door_open_inside_right';
            AnimDuration = 1.38;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            // Setup ShadowProxyDoorAnimNode like SM 28
            if (RemoteHero.ShadowProxyDoorAnimNode != None)
            {
                RemoteHero.ShadowProxyDoorAnimNode.SetActiveChild(DoorDir, 1.0);
                RemoteHero.ShadowProxyDoorAnimNode.PlayRate = 0.5;
                RemoteHero.ShadowProxyDoorAnimNode.MaxRatio = 1.0;
            }
            break;
            
        case 30: // SMT_OpenDoorPartial
            // Don't lock position - let interpolation handle it
            bIsLeft = (DoorDir <= 1);
            bIsPush = (DoorDir == 0 || DoorDir == 2);
            if (bIsPush)
                AnimName = bIsLeft ? 'player_door_open_push_left' : 'player_door_open_push_right';
            else
                AnimName = bIsLeft ? 'player_door_open_inside_left' : 'player_door_open_inside_right';
            AnimDuration = 1.38;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        case 31: // SMT_TryOpenLockedDoor
            // Don't lock position - let interpolation handle it
            bIsLeft = (DoorDir == 0 || DoorDir == 1);
            AnimName = bIsLeft ? 'player_door_locked_left' : 'player_door_locked_right';
            AnimDuration = 2.71;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        case 32: // SMT_RunThroughDoor
            // Don't lock position - let interpolation handle it
            bIsLeft = (DoorDir == 0 || DoorDir == 1);
            AnimName = bIsLeft ? 'player_run_door_open_left' : 'player_run_door_open_right';
            AnimDuration = 1.25;
            BlendIn = 0.15;
            BlendOut = 0.15;
            bPositionLocked = false;
            break;
            
        case 33: // SMT_CloseDoor
        case 34: // SMT_CloseDoorPositionned
            // Don't lock position - let interpolation handle it
            switch (DoorDir)
            {
                case 0: AnimName = 'player_door_close_left_front'; break;
                case 1: AnimName = 'player_door_close_left_side'; break;
                case 2: AnimName = 'player_door_close_left_back'; break;
                case 3: AnimName = 'player_door_close_inside_left'; break;
                case 4: AnimName = 'player_door_close_right_front'; break;
                case 5: AnimName = 'player_door_close_right_side'; break;
                case 6: AnimName = 'player_door_close_right_back'; break;
                case 7: AnimName = 'player_door_close_inside_right'; break;
                default: AnimName = 'player_door_close_left_front'; break;
            }
            AnimDuration = 1.25;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        // === LOCKER ===
        case 37: // SMT_OpenLockerFromOutside
            // OLHero.cpp line 1143-1153: PlayBlendedAnim(Straight, 45Left/Right, alpha, 0.25, 0.5)
            AnimName = bIsLeft ? 'player_locker_open_left_45' : 'player_locker_open_right_45';
            AnimDuration = 1.58;
            BlendIn = 0.25;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        case 38: // SMT_EnterLocker
            // OLHero.cpp line 1155-1158: PlayFullBodyAnim(AnimNameHideInLocker, 1.f, 0.25f, 0.25f)
            AnimName = 'player_locker_hide';
            AnimDuration = 3.46;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        case 39: // SMT_ExitLocker
            // OLHero.cpp: exit locker animation
            AnimName = 'player_locker_exit';
            AnimDuration = 1.25;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        // === BED ===
        // OLHero.cpp line 1176-1199: left/right, crouched/standing variants
        // Gap fix: start bed_idle early to bridge gap before locomotion mode changes
        case 40: // SMT_EnterBed
            if (bCurrentLeftAnim)
                AnimName = bCurrentCrouched ? 'player_enter_bed_left' : 'player_enter_bed_left_stand';
            else
                AnimName = bCurrentCrouched ? 'player_enter_bed_right' : 'player_enter_bed_right_stand';
            AnimDuration = bCurrentCrouched ? 1.1667 : 1.5;
            BlendIn = 0.25;
            BlendOut = 0.15;
            bPositionLocked = false;
            break;
            
        case 41: // SMT_ExitBed
            if (bCurrentLeftAnim)
                AnimName = bCurrentCrouched ? 'player_exit_bed_left_crouch' : 'player_exit_bed_left';
            else
                AnimName = bCurrentCrouched ? 'player_exit_bed_right_crouch' : 'player_exit_bed_right';
            AnimDuration = bCurrentCrouched ? 1.6 : 2.0;
            BlendIn = 0.25;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        // === LADDER ===
        case 43: // SMT_EnterLadderFromGround
            // OLHero.cpp line 830-842: PlayBlendedAnim(Straight, 45Left/Right, alpha, 0.25, 0.05)
            AnimName = 'player_ladder_grab_straight';
            AnimDuration = 0.83;
            BlendIn = 0.25;
            BlendOut = 0.05;
            bPositionLocked = false;
            break;
            
        case 44: // SMT_EnterLadderFromAbove
            // OLHeroData.uci: AnimName=player_ladder_enter_above
            AnimName = 'player_ladder_enter_above';
            AnimDuration = 3.33;
            BlendIn = 0.25;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        case 45: // SMT_ExitLadderOnGround
            // Just release the ladder, no specific hero anim - use brief exit
            AnimName = 'player_ladder_grab_straight';
            AnimDuration = 0.83;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        case 46: // SMT_ExitLadderOnTop
            // OLHero.cpp line 843-853: PlayFullBodyAnim(ExitLadderOnTopLH/RH, 1.f, 0.25f, 0.5f)
            AnimName = 'player_ladder_exit_lh';
            AnimDuration = 2.88;
            BlendIn = 0.25;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        case 47: // SMT_DropFromLadder
            AnimName = 'player_falling_loop';
            AnimDuration = 1.0;
            BlendIn = 0.1;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        case 48: // SMT_GrabLadderFromAir
            // OLHeroData.uci: AnimName=player_ladder_grab_from_air
            AnimName = 'player_ladder_grab_from_air';
            AnimDuration = 0.33;
            BlendIn = 0.1;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        // === PICKUP OBJECT ===
        case 49: // SMT_PickupObject
            // OLHero.cpp line 856-939: BlendSpace for document vs object, standing vs crouched
            // Use middle blend for remote - most common pickup
            AnimName = 'player_object_pickup_h62v105';
            AnimDuration = 1.25;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        // === CSA (Context Sensitive Action) ===
        case 50: // SMT_CSA
            // OLHero.cpp line 942-948: PlayFullBodyAnim(ActiveCSA->AnimName, 1.f, 0.25f, 0.5f)
            // CSA uses dynamic animation name from the CSA actor - we can't know it in advance
            // Use a generic pickup animation as fallback
            AnimName = 'player_object_pickup_h62v105';
            AnimDuration = 1.25;
            BlendIn = 0.25;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        // === PUSH OBJECT ===
        case 54: // SMT_StartPushingObject
            // OLHero.cpp line 1303-1306: PlayFullBodyAnim(EnterPushObjectLeft/Right, 1.0f, 0.25f, 0.25f)
            AnimName = 'player_push_object_enter_left';
            AnimDuration = 0.83;
            BlendIn = 0.25;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        case 55: // SMT_StopPushingObject
            // OLHero.cpp line 1308-1311: PlayFullBodyAnim(ExitPushObjectLeft/Right, 1.0f, 0.25f, 0.5f)
            AnimName = 'player_push_object_exit_left';
            AnimDuration = 1.25;
            BlendIn = 0.25;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        // === PUSH FROM LEDGE ===
        case 56: // SMT_PushFromLedgeProcedural
        case 57: // SMT_PushFromLedgeAnimated
            // OLHero.cpp: pushaway animations
            AnimName = 'player_pushaway_left';
            AnimDuration = 1.04;
            BlendIn = 0.1;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        // === CONTEXTUAL LEAN ===
        // Lean is driven by the animation tree via CurrentLean, not by special move animations.
        // These SMs just transition locomotion mode — no specific full-body anim needed.
        case 58: // SMT_EnterContextualLean
        case 59: // SMT_ExitContextualLean
        case 60: // SMT_ExitContextualLeanForward
        case 61: // SMT_ContextualLeanInsideTransition
            AnimName = 'None';
            AnimDuration = 0.5;
            BlendIn = 0.1;
            BlendOut = 0.25;
            bPositionLocked = false;
            break;
            
        // === HERO GRABBED (player_hit) ===
        case 62: // SMT_HeroGrabbedNormal
            // OLHero.cpp line 1313-1351: PlayBlendedAnim(GrabNormal/Left90/Right90/etc, alpha, 0.1f, 0.5f)
            AnimName = 'player_hit_forward';
            AnimDuration = 1.375;
            BlendIn = 0.1;
            BlendOut = 0.5;
            bPositionLocked = false;
            break;
            
        default:
            return;
    }
    
    // Play animation (original PlayBodyAnim does NOT call StopCustomAnim first)
    // But we need to stop crouch transition if it's playing
    if (bPlayingCrouchTransition && RemoteHero.ShadowProxyFullBodyAnimSlot != None)
    {
        `log("[ANIM_STOP] Stopping crouch transition before playing" @ AnimName);
        RemoteHero.ShadowProxyFullBodyAnimSlot.StopCustomAnim(0.0);
        bPlayingCrouchTransition = false;
    }
    `log("[ANIM_BEFORE] bPlayingSpecialAnim:" @ bPlayingSpecialAnim @ "CurrentSM:" @ CurrentSpecialMove @ "Slot:" @ (RemoteHero.ShadowProxyFullBodyAnimSlot != None) @ "Time:" @ WorldInfo.TimeSeconds);
    RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim(AnimName, 1.0, BlendIn, BlendOut, false, false);
    `log("[ANIM_PLAY] Played:" @ AnimName @ "BlendIn:" @ BlendIn @ "BlendOut:" @ BlendOut @ "Duration:" @ AnimDuration @ "SM:" @ MoveType @ "SlotAnim:" @ RemoteHero.ShadowProxyFullBodyAnimSlot.GetPlayedAnimation() @ "Time:" @ WorldInfo.TimeSeconds);
    bPlayingSpecialAnim = true;
    SpecialAnimStartTime = WorldInfo.TimeSeconds;
    SpecialAnimDuration = AnimDuration;
    CurrentSpecialMove = MoveType;
    LastPlayedSpecialMove = MoveType;
}

function EndSpecialMoveAnim()
{
    if (RemoteHero == None) return;
    
    `log("[ANIM_END] Stopping anim, SM:" @ CurrentSpecialMove @ "was playing for:" @ (WorldInfo.TimeSeconds - SpecialAnimStartTime) @ "CurrentAnim:" @ RemoteHero.ShadowProxyFullBodyAnimSlot.GetPlayedAnimation() @ "bPlayingSpecialAnim:" @ bPlayingSpecialAnim @ "Time:" @ WorldInfo.TimeSeconds);
    bPlayingSpecialAnim = false;
    bPositionLocked = false;
    bDoorAnimFlipped = false;
    bWaitingForInstantVault = false;
    PendingVaultMoveType = 0;
    bPendingVaultRunning = false;
    CurrentSpecialMove = 0;
    InstantVaultDelayTime = 0.0;
    
    // Stop with 0.1s blend (from OLHero::PlayFullBodyAnim line 8540)
    if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
    {
        RemoteHero.ShadowProxyFullBodyAnimSlot.StopCustomAnim(0.1);
        `log("[ANIM_END_STOP] StopCustomAnim(0.1) called. Time:" @ WorldInfo.TimeSeconds);
    }
}

event Tick(float DeltaTime)
{
    local float HostTime, RenderTime;
    local OLTogetherNetworkState.CompactState Before, After, Desired;
    local float Alpha, MoveDist, ElapsedAnimTime;
    local vector MoveDelta, ProjectedLoc, InterpLoc;
    local rotator DesiredRot;
    local bool bHostEndedSpecialMove, bIsVault;
    
    if (!bHasState || NetworkState == None || NetworkState.StateBuffer.Length == 0 || RemoteHero == None)
        return;
    
    HostTime = GetHostTime();
    RenderTime = HostTime - NetworkState.AdaptiveDelay;  // Use adaptive delay instead of fixed
    
    if (!FindBracketingStates(RenderTime, Before, After, Alpha))
        return;
    
    // Hermite interpolation for smoother movement (uses velocity for curved path)
    Desired.Location = NetworkState.HermiteInterp(Before.Location, Before.Velocity, After.Location, After.Velocity, Alpha, FMax(After.TimeStamp - Before.TimeStamp, 0.0001));
    Desired.Velocity = VLerp(Before.Velocity, After.Velocity, Alpha);
    Desired.Yaw = NetworkState.CubicRotationInterp(Before.Yaw, After.Yaw, Alpha);
    
    // Unpack flags
    Desired.PackedFlags = After.PackedFlags;
    Desired.LocomotionMode = After.LocomotionMode;
    Desired.SpecialMove = After.SpecialMove;
    Desired.DoorDir = After.DoorDir;
    Desired.LeanDir = After.LeanDir;
    Desired.ExtraData = After.ExtraData;
    Desired.ExtraKind = After.ExtraKind;
    Desired.Health = After.Health;
    Desired.CamcorderState = After.CamcorderState;
    Desired.DoorRatio = After.DoorRatio;
    
    bIsVault = (CurrentSpecialMove == 5 || CurrentSpecialMove == 6 || CurrentSpecialMove == 7
        || CurrentSpecialMove == 8 || CurrentSpecialMove == 14 || CurrentSpecialMove == 15
        || CurrentSpecialMove == 16 || CurrentSpecialMove == 17 || CurrentSpecialMove == 18
        || CurrentSpecialMove == 19 || CurrentSpecialMove == 20 || CurrentSpecialMove == 21
        || CurrentSpecialMove == 22 || CurrentSpecialMove == 23
        || CurrentSpecialMove == 28 || CurrentSpecialMove == 29
        || CurrentSpecialMove == 30 || CurrentSpecialMove == 31 || CurrentSpecialMove == 32
        || CurrentSpecialMove == 33 || CurrentSpecialMove == 34);
    
    // Handle animation locking (vault, door, climb, slide)
    if (bPlayingSpecialAnim)
    {
        ElapsedAnimTime = WorldInfo.TimeSeconds - SpecialAnimStartTime;
        // SM 14 (GrabLedgeFromGround) and SM 15 (GrabLedgeFromAir) need special handling
        // The grab anim is 1s, but we need to start the ledge idle BEFORE it ends to avoid gap
        if (CurrentSpecialMove == 14 || CurrentSpecialMove == 15)
        {
            `log("[LEDGE_GRAB_TICK] SM:" @ CurrentSpecialMove @ "Elapsed:" @ ElapsedAnimTime @ "Duration:" @ SpecialAnimDuration @ "LM_desired:" @ Desired.LocomotionMode @ "LM_current:" @ CurrentLocomotionMode @ "bPlayingAnim:" @ bPlayingSpecialAnim @ "bLedgeIdleStarted:" @ bLedgeIdleStarted @ "Time:" @ WorldInfo.TimeSeconds);
            
            // Start ledge idle at 0.75s (before the 1s grab anim ends) to bridge the gap
            if (!bLedgeIdleStarted && ElapsedAnimTime > 0.75 && RemoteHero.ShadowProxyFullBodyAnimSlot != None)
            {
                `log("[LEDGE_GRAB_BRIDGE] Starting player_ledge_idle early at" @ ElapsedAnimTime @ "to bridge gap. Time:" @ WorldInfo.TimeSeconds);
                RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_idle', 1.0, 0.25, 0.0, true, false);
                bLedgeIdleStarted = true;
            }
            
            // End when the animation duration is complete OR host explicitly ends
            bHostEndedSpecialMove = (Desired.SpecialMove == 0 && CurrentSpecialMove != 0)
                || (ElapsedAnimTime > SpecialAnimDuration - 0.1);
        }
        // SM 40 (EnterBed) - same pattern as ledge: bridge idle early, then fallthrough
        else if (CurrentSpecialMove == 40)
        {
            `log("[BED_TICK] SM:40 Elapsed:" @ ElapsedAnimTime @ "Duration:" @ SpecialAnimDuration @ "bBedIdleStarted:" @ bBedIdleStarted @ "Time:" @ WorldInfo.TimeSeconds);
            
            // Start bed idle early to bridge gap, like ledge does at 0.75s
            if (!bBedIdleStarted && ElapsedAnimTime > SpecialAnimDuration - 0.3 && RemoteHero.ShadowProxyFullBodyAnimSlot != None)
            {
                `log("[BED_BRIDGE] Starting player_bed_idle early at" @ ElapsedAnimTime @ "Time:" @ WorldInfo.TimeSeconds);
                RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_bed_idle', 1.0, 0.25, 0.0, true, false);
                bBedIdleStarted = true;
            }
            
            bHostEndedSpecialMove = (Desired.SpecialMove == 0 && CurrentSpecialMove != 0)
                || (ElapsedAnimTime > SpecialAnimDuration - 0.1);
        }
        else
        {
            bHostEndedSpecialMove = (Desired.SpecialMove == 0 && CurrentSpecialMove != 0)
                || (ElapsedAnimTime > SpecialAnimDuration);
        }
        
        // SM changed to a new non-zero value - let PlayCustomAnim replace directly
        if (!bHostEndedSpecialMove && Desired.SpecialMove != 0 && Desired.SpecialMove != CurrentSpecialMove)
        {
            `log("[ANIM_SM_CHANGE] SM" @ CurrentSpecialMove @ "->" @ Desired.SpecialMove @ "Time:" @ WorldInfo.TimeSeconds);
            bPlayingSpecialAnim = false;  // Allow new SM to start
            bPositionLocked = false;
        }
        
        if (bHostEndedSpecialMove)
        {
            `log("[SM_END] SM:" @ CurrentSpecialMove @ "LM_desired:" @ Desired.LocomotionMode @ "LM_current:" @ CurrentLocomotionMode @ "Elapsed:" @ (WorldInfo.TimeSeconds - SpecialAnimStartTime) @ "bPlaying:" @ bPlayingSpecialAnim @ "Time:" @ WorldInfo.TimeSeconds);
            // For ledge grab and bed SMs: reset state but DON'T return early
            // Let the locomotion mode update happen in the same frame to avoid 1-frame gap
            if (CurrentSpecialMove == 14 || CurrentSpecialMove == 15)
            {
                `log("[SM_FALLTHROUGH_END] SM:" @ CurrentSpecialMove @ "Time:" @ WorldInfo.TimeSeconds);
                bPlayingSpecialAnim = false;
                bPositionLocked = false;
                bLockRotation = true;
                bDoorAnimFlipped = false;
                bWaitingForInstantVault = false;
                PendingVaultMoveType = 0;
                bPendingVaultRunning = false;
                CurrentSpecialMove = 0;
                InstantVaultDelayTime = 0.0;
                // Don't return - fall through to locomotion mode update below
            }
            // Bed enter/exit: same fall-through
            else if (CurrentSpecialMove == 40 || CurrentSpecialMove == 41)
            {
                `log("[SM_BED_FALLTHROUGH] SM:" @ CurrentSpecialMove @ "Time:" @ WorldInfo.TimeSeconds);
                bPlayingSpecialAnim = false;
                bPositionLocked = false;
                bLockRotation = true;
                bWaitingForInstantVault = false;
                PendingVaultMoveType = 0;
                bPendingVaultRunning = false;
                InstantVaultDelayTime = 0.0;
                // Keep CurrentSpecialMove so next frame doesn't re-trigger
                // Don't return - fall through to locomotion mode update below
            }
            else
            {
                EndSpecialMoveAnim();
                PredictedLocation = RemoteHero.Location;
                PredictedYaw = RemoteHero.Rotation.Yaw;
                return;
            }
        }
        else if (bPositionLocked)
        {
            // Lock position during animation - project along forward vector only
            ProjectedLoc = Desired.Location - VaultLockStartPos;
            ProjectedLoc = VaultLockStartPos + VaultLockFwd * (ProjectedLoc.X * VaultLockFwd.X + ProjectedLoc.Y * VaultLockFwd.Y);
            ProjectedLoc.Z = Desired.Location.Z;
            RemoteHero.SetLocation(ProjectedLoc);
            // Don't lock rotation during door interactions (SM 28-34)
            // But during entry animation (DoorRatio=0), let the animation drive rotation
            // Only apply network rotation after door hold starts (DoorRatio > 0)
            if (CurrentSpecialMove >= 28 && CurrentSpecialMove <= 34)
            {
                if (Desired.DoorRatio > 0.0)
                {
                    // Door hold active - use network rotation
                    RemoteHero.SetRotation(DesiredRot);
                    PredictedYaw = DesiredRot.Yaw;
                }
                // else: entry animation playing - let anim node drive rotation
            }
            else if (!bLockRotation)
            {
                // Position locked but rotation not locked - let animation drive rotation
                // (e.g. LedgeWalkTransition 90-degree corner turn)
            }
            else
            {
                RemoteHero.SetRotation(VaultLockRot);
                PredictedYaw = VaultLockRot.Yaw;
            }
            RemoteHero.Velocity = vect(0,0,0);
            RemoteHero.Acceleration = vect(0,0,0);
            PredictedLocation = ProjectedLoc;
            return;
        }
    }
    
    // Handle new special move start
    `log("[SM_CHECK] SM_desired:" @ Desired.SpecialMove @ "SM_current:" @ CurrentSpecialMove @ "bPlaying:" @ bPlayingSpecialAnim @ "LM:" @ Desired.LocomotionMode @ "Time:" @ WorldInfo.TimeSeconds);
    if (!bPlayingSpecialAnim && Desired.SpecialMove != 0 && Desired.SpecialMove != CurrentSpecialMove)
    {
        `log("[SPECIAL_MOVE] SM=" @ Desired.SpecialMove @ "LM=" @ Desired.LocomotionMode @ "bPlaying=" @ bPlayingSpecialAnim @ "Time:" @ WorldInfo.TimeSeconds);
        // Crouch/Uncrouch (1,2) handled by crouch state handler above - skip here
        if (Desired.SpecialMove == 1 || Desired.SpecialMove == 2)
        {
            // Do nothing - crouch handled by bCrouched state change
        }
        // Check if this is a position-locked move that needs approach phase
        // SMs 5-8 (vault/slide/climb) and SM 14 (grab ledge from ground) have approach phases
        else if ((Desired.SpecialMove == 5 || Desired.SpecialMove == 6 || Desired.SpecialMove == 7
            || Desired.SpecialMove == 8 || Desired.SpecialMove == 14) && (Desired.PackedFlags & 8) == 0)
        {
            // Approach phase - don't play animation yet
        }
        else if ((Desired.SpecialMove == 5 || Desired.SpecialMove == 6 || Desired.SpecialMove == 7
            || Desired.SpecialMove == 8 || Desired.SpecialMove == 14) && (Desired.PackedFlags & 8) != 0 && !bWaitingForInstantVault)
        {
            // Instant vault/slide/climb - add small delay for position sync
            bWaitingForInstantVault = true;
            PendingVaultMoveType = Desired.SpecialMove;
            bPendingVaultRunning = (Desired.PackedFlags & 4) != 0;
            InstantVaultDelayTime = WorldInfo.TimeSeconds;
        }
        else
        {
            // Door, crouch, jump, etc - play immediately
            PlaySpecialMoveAnim(Desired.SpecialMove, (Desired.PackedFlags & 4) != 0);
            return;
        }
    }
    
    // Execute pending instant vault after delay
    if (bWaitingForInstantVault && PendingVaultMoveType != 0)
    {
        if (WorldInfo.TimeSeconds - InstantVaultDelayTime > 0.05)
        {
            PlaySpecialMoveAnim(PendingVaultMoveType, bPendingVaultRunning);
            PendingVaultMoveType = 0;
            bWaitingForInstantVault = false;
            return;
        }
    }
    
    // Compute desired rotation early - needed by position locking code below
    // Use mesh rotation (body facing direction) instead of camera rotation
    DesiredRot = DesiredMeshRotation;
    DesiredRot.Pitch = 0;
    DesiredRot.Roll = 0;
    
    // Movement interpolation with teleport threshold
    MoveDelta = Desired.Location - RemoteHero.Location;
    MoveDelta.Z = 0;
    MoveDist = VSize(MoveDelta);
    
    if (MoveDist > TeleportDistThreshold)
    {
        // Large distance - teleport with a smooth blend-in from current position
        // Blend 50% toward target on first frame to avoid hard snap
        InterpLoc = VInterpTo(RemoteHero.Location, Desired.Location, DeltaTime, InterpSpeed * 0.5);
        RemoteHero.SetLocation(InterpLoc);
        PredictedLocation = InterpLoc;
    }
    else if (MoveDist > 1.0)
    {
        // Normal movement - smooth interpolation with speed-scaled rate
        // Faster when far, slower when close for natural deceleration feel
        InterpLoc = VInterpTo(RemoteHero.Location, Desired.Location, DeltaTime, InterpSpeed);
        RemoteHero.SetLocation(InterpLoc);
        PredictedLocation = InterpLoc;
    }
    else
    {
        // Very close - snap to avoid micro-jitter
        RemoteHero.SetLocation(Desired.Location);
        PredictedLocation = Desired.Location;
    }
    
    // Always apply mesh rotation (body facing direction from host)
    // Use smooth interpolation for natural-looking turns
    RemoteHero.SetRotation(RInterpTo(RemoteHero.Rotation, DesiredMeshRotation, DeltaTime, 12.0));
    
    RemoteHero.Velocity = Desired.Velocity;
    RemoteHero.Acceleration = Desired.Velocity;
    
    // Update locomotion mode
    if (Desired.LocomotionMode != CurrentLocomotionMode)
    {
        `log("[LOCO_CHANGE] OLD:" @ CurrentLocomotionMode @ "NEW:" @ Desired.LocomotionMode @ "SM:" @ CurrentSpecialMove @ "bPlaying:" @ bPlayingSpecialAnim @ "Time:" @ WorldInfo.TimeSeconds);
        switch (Desired.LocomotionMode)
        {
            case 0:  RemoteHero.LocomotionMode = LM_Walk; break;
            case 1:  RemoteHero.LocomotionMode = LM_Fall; break;
            case 2:  RemoteHero.LocomotionMode = LM_SpecialMove; break;
            case 3:  RemoteHero.LocomotionMode = LM_Ladder; break;
            case 4:
                RemoteHero.LocomotionMode = LM_LedgeHang;
                `log("[LEDGE_HANG_ENTER] Entering LM_LedgeHang. SM:" @ CurrentSpecialMove @ "bPlayingSpecialAnim:" @ bPlayingSpecialAnim @ "CurrentAnim:" @ RemoteHero.ShadowProxyFullBodyAnimSlot.GetPlayedAnimation() @ "Time:" @ WorldInfo.TimeSeconds);
                // Snap to network position - hero should be at ledge position now
                RemoteHero.SetLocation(Desired.Location);
                PredictedLocation = Desired.Location;
                RemoteHero.Velocity = vect(0,0,0);
                RemoteHero.Acceleration = vect(0,0,0);
                // Start ledge idle immediately - ShadowProxy anim tree doesn't auto-play it
                if (RemoteHero.ShadowProxyFullBodyAnimSlot != None && !bPlayingSpecialAnim)
                {
                    `log("[LEDGE_HANG_IDLE] Starting player_ledge_idle (bPlayingSpecialAnim=false, slot available)");
                    RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_idle', 1.0, 0.0, 0.0, true, false);
                }
                else
                {
                    `log("[LEDGE_HANG_SKIP] NOT starting idle. bPlayingSpecialAnim:" @ bPlayingSpecialAnim @ "Slot:" @ (RemoteHero.ShadowProxyFullBodyAnimSlot != None));
                }
                break;
            case 5:
                RemoteHero.LocomotionMode = LM_LedgeWalk;
                // Start ledge walk idle immediately
                if (RemoteHero.ShadowProxyFullBodyAnimSlot != None && !bPlayingSpecialAnim)
                {
                    RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_walk_idle', 1.0, 0.1, 0.0, true, false);
                    `log("[LEDGE_WALK] Starting ledge_walk_idle Time:" @ WorldInfo.TimeSeconds);
                }
                break;
            case 6:  RemoteHero.LocomotionMode = LM_Squeeze; break;
            case 7:  RemoteHero.LocomotionMode = LM_Door; break;
            case 8:  RemoteHero.LocomotionMode = LM_Locker; break;
            case 9:
                RemoteHero.LocomotionMode = LM_Cinematic;
                `log("[CUTSCENE_ENTER] Entering LM_Cinematic. CutsceneID:" @ Desired.ExtraData @ "Time:" @ WorldInfo.TimeSeconds);
                // Play the cutscene animation based on ExtraData (cutscene ID)
                if (Desired.ExtraData != CurrentCutsceneAnim && Desired.ExtraData != 0)
                {
                    PlayCutsceneAnimation(Desired.ExtraData);
                    CurrentCutsceneAnim = Desired.ExtraData;
                }
                // Snap position and rotation
                RemoteHero.SetLocation(Desired.Location);
                PredictedLocation = Desired.Location;
                RemoteHero.Velocity = vect(0,0,0);
                RemoteHero.Acceleration = vect(0,0,0);
                break;
                case 10:
                    // Don't set LM_Bed while SM 40 (enter bed) is still playing
                    // The enter bed anim plays in LM_Walk, then transitions to LM_Bed after
                    if (CurrentSpecialMove == 40)
                    {
                        `log("[LOCO_BED_SKIP] SM 40 still active, deferring LM_Bed Time:" @ WorldInfo.TimeSeconds);
                    }
                    else
                    {
                        RemoteHero.LocomotionMode = LM_Bed;
                        `log("[LOCO_BED] Setting LM_Bed. SM_current:" @ CurrentSpecialMove @ "bPlaying:" @ bPlayingSpecialAnim @ "Time:" @ WorldInfo.TimeSeconds);
                    }
                    break;
            case 11: RemoteHero.LocomotionMode = LM_LookBack; break;
            case 12: RemoteHero.LocomotionMode = LM_Struggle; break;
            case 13: RemoteHero.LocomotionMode = LM_Grabbed; break;
            case 14: RemoteHero.LocomotionMode = LM_Pushing; break;
            case 15: RemoteHero.LocomotionMode = LM_ContextualLean; break;
        }
        // Handle exiting cutscene mode
        if (CurrentLocomotionMode == 9 && Desired.LocomotionMode != 9)
        {
            `log("[CUTSCENE_EXIT] Exiting LM_Cinematic Time:" @ WorldInfo.TimeSeconds);
            bPlayingCutscene = false;
            CurrentCutsceneAnim = 0;
        }
        CurrentLocomotionMode = Desired.LocomotionMode;
    }
    
    // Lean handling
    if (Desired.LeanDir != 0 && ((Desired.PackedFlags & 1) != 0 || VSize(Desired.Velocity) < 50.0))
        RemoteHero.CurrentLean = (Desired.LeanDir == 1) ? -1.0 : 1.0;
    else
        RemoteHero.CurrentLean = 0.0;
    
    // Track lean direction for crouch lean animations
    CurrentLeanDir = Desired.LeanDir;
    
    // Crouch handling
    if (((Desired.PackedFlags & 1) != 0) != bCurrentCrouched)
    {
        bCurrentCrouched = (Desired.PackedFlags & 1) != 0;
        
        // Exact match from original OLTogetherController line 1092-1099
        AnimLockEndTime = WorldInfo.TimeSeconds + 0.55;
        if (bCurrentCrouched)
        {
            RemoteHero.ForceCrouch();
            if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
            {
                RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_stand_to_crouch', 1.0, 0.1, 0.0, false, false);
                `log("[ANIM_CROUCH] stand_to_crouch Time:" @ WorldInfo.TimeSeconds);
            }
        }
        else
        {
            RemoteHero.UnCrouch();
            if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
            {
                RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_crouch_to_stand', 1.0, 0.1, 0.0, false, false);
                `log("[ANIM_CROUCH] crouch_to_stand Time:" @ WorldInfo.TimeSeconds);
            }
        }
        LastMovementAnim = 'None';
    }
    
    // Drive idle/movement animations (from original UpdateDummyMovementAnim)
    UpdateDummyMovementAnim();
    
    // Ledge move animations - play shimmy anims based on velocity direction
    // LM_LedgeHang (4) uses player_ledge_* anims
    // LM_LedgeWalk (5) uses player_ledge_walk_* anims
    // Use Desired.Velocity (network) since we clear RemoteHero.Velocity for ledge modes
    if (CurrentLocomotionMode == 4 && !bPlayingSpecialAnim)
    {
        // Ledge Hang - use player_ledge_* anims
        if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
        {
            if (VSize(Desired.Velocity) != 0.0)
            {
                if (Desired.Velocity.X * -Sin(RemoteHero.Rotation.Yaw * 3.1415927 / 32768.0)
                    + Desired.Velocity.Y * Cos(RemoteHero.Rotation.Yaw * 3.1415927 / 32768.0) > 0.0)
                {
                    if (LastMovementAnim != 'player_ledge_move_right')
                    {
                        LastMovementAnim = 'player_ledge_move_right';
                        RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_move_right', 1.0, 0.1, 0.0, true, false);
                    }
                    else if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                        RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 1.0;
                }
                else
                {
                    if (LastMovementAnim != 'player_ledge_move_left')
                    {
                        LastMovementAnim = 'player_ledge_move_left';
                        RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_move_left', 1.0, 0.1, 0.0, true, false);
                    }
                    else if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                        RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 1.0;
                }
            }
            else if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 0.0;
        }
    }
    else if (CurrentLocomotionMode == 5 && !bPlayingSpecialAnim)
    {
        // Ledge Walk - use player_ledge_walk_* anims
        if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
        {
            if (VSize(Desired.Velocity) != 0.0)
            {
                if (Desired.Velocity.X * -Sin(RemoteHero.Rotation.Yaw * 3.1415927 / 32768.0)
                    + Desired.Velocity.Y * Cos(RemoteHero.Rotation.Yaw * 3.1415927 / 32768.0) > 0.0)
                {
                    if (LastMovementAnim != 'player_ledge_walk_move_right')
                    {
                        LastMovementAnim = 'player_ledge_walk_move_right';
                        RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_walk_move_right', 1.0, 0.1, 0.0, true, false);
                    }
                    else if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                        RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 1.0;
                }
                else
                {
                    if (LastMovementAnim != 'player_ledge_walk_move_left')
                    {
                        LastMovementAnim = 'player_ledge_walk_move_left';
                        RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_walk_move_left', 1.0, 0.1, 0.0, true, false);
                    }
                    else if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                        RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 1.0;
                }
            }
            else if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 0.0;
        }
    }
    
    // Camcorder handling
    if (((Desired.PackedFlags & 2) != 0) != bCurrentCamcorder || Desired.CamcorderState != CurrentCamcorderState)
    {
        if (CurrentLocomotionMode != 3 && CurrentLocomotionMode != 4)
        {
            OnCamcorderChange((Desired.PackedFlags & 2) != 0, Desired.CamcorderState);
            bCurrentCamcorder = (Desired.PackedFlags & 2) != 0;
            CurrentCamcorderState = Desired.CamcorderState;
        }
    }
    
    // Door hold sync - sync ShadowProxyDoorAnimNode ratio from host
    // From OLHero.cpp: DoorAnimNode->CurrentRatio drives the door open/close animation
    if (Desired.SpecialMove == 28 && RemoteHero.ShadowProxyDoorAnimNode != None)
    {
        RemoteHero.ShadowProxyDoorAnimNode.CurrentRatio = Desired.DoorRatio;
        RemoteHero.ShadowProxyDoorAnimNode.MaxRatio = 1.0;
        `log("[DOOR_SYNC] Ratio:" @ Desired.DoorRatio @ "DoorDir:" @ Desired.DoorDir @ "HostYaw:" @ Desired.Yaw @ "RemoteYaw:" @ RemoteHero.Rotation.Yaw @ "Time:" @ WorldInfo.TimeSeconds);
    }
    
    // Apply synced door state (actual door mesh movement)
    ApplyDoorSync();
    ApplyDoorBreakState();
    
    CurrentDoorDir = Desired.DoorDir;
    CurrentExtraData = Desired.ExtraData;
    CurrentExtraKind = Desired.ExtraKind;
    CurrentHealth = Desired.Health;
    
    // ExtraData contains bLeftAnim when not in cinematic mode
    if (CurrentLocomotionMode != 9)
        bCurrentLeftAnim = (Desired.ExtraData != 0);
    
    // Debug: log current state every frame
    if (bPlayingSpecialAnim || CurrentLocomotionMode == 4 || CurrentLocomotionMode == 5)
    {
        `log("[REMOTE_STATE] SM:" @ CurrentSpecialMove @ "LM:" @ CurrentLocomotionMode @ "bPosLock:" @ bPositionLocked @ "Anim:" @ RemoteHero.ShadowProxyFullBodyAnimSlot.GetPlayedAnimation() @ "Elapsed:" @ (WorldInfo.TimeSeconds - SpecialAnimStartTime) @ "Time:" @ WorldInfo.TimeSeconds);
    }
}

function SetRemoteSpecialStart(int MoveType, bool bRunning)
{
    // Handled by state packets now
}

function SetRemoteSpecialEnd()
{
    if (bPlayingSpecialAnim)
        EndSpecialMoveAnim();
}

// Door sync: receive host's active door state
function SyncDoorState(int DoorId, float DoorOpenRatio)
{
    SyncDoorId = DoorId;
    SyncDoorOpenRatio = DoorOpenRatio;
    
    // Find the door if we don't have it cached, or if the ID changed (different door)
    if (DoorId == 0)
    {
        SyncedDoor = None;
        return;
    }
    
    // Need to find a new door
    if (SyncedDoor == None || !IsDoorMatchingId(SyncedDoor, DoorId))
    {
        SyncedDoor = FindDoorById(DoorId);
    }
}

function SetDoorBreakState(int BreakState)
{
    if (SyncedDoor == None || SyncDoorBreakState == BreakState)
        return;
    
    SyncDoorBreakState = BreakState;
    ApplyDoorBreakState();
}

// Handle door bash/break event from host - find the door and call the native event
function HandleDoorBreakEvent(int DoorId, int BreakState)
{
    local OLDoor Door;
    
    Door = FindDoorById(DoorId);
    if (Door == None)
    {
        `log("[DOOR_BREAK] Door not found for ID:" @ DoorId @ "Time:" @ WorldInfo.TimeSeconds);
        return;
    }
    
    `log("[DOOR_BREAK] Received DoorId:" @ DoorId @ "State:" @ BreakState @ "Door:" @ Door @ "DoorBreakState:" @ Door.DoorBreakState @ "Time:" @ WorldInfo.TimeSeconds);
    
    if (BreakState == 1) // Bash - can happen multiple times
    {
        `log("[DOOR_BASH] Calling BashDoor on:" @ Door);
        Door.BashDoor(false);
    }
    else if (BreakState == 2 && Door.DoorBreakState != 2) // Break - only if not already broken
    {
        `log("[DOOR_BREAK] Calling BreakDoor on:" @ Door);
        Door.BreakDoor(None, false);
    }
}

// Apply door break state by calling the door's native events
// DBS_Normal=0, DBS_Breaking=1, DBS_Broken=2
function ApplyDoorBreakState()
{
    if (SyncedDoor == None)
        return;
    
    if (SyncDoorBreakState == 1 && SyncedDoor.DoorBreakState == 0) // DBS_Breaking, only if currently normal
    {
        `log("[DOOR_BASH] Calling BashDoor on:" @ SyncedDoor @ "Time:" @ WorldInfo.TimeSeconds);
        SyncedDoor.BashDoor(false);
    }
    else if (SyncDoorBreakState == 2 && SyncedDoor.DoorBreakState != 2) // DBS_Broken, only if not already broken
    {
        `log("[DOOR_BREAK] Calling BreakDoor on:" @ SyncedDoor @ "Time:" @ WorldInfo.TimeSeconds);
        SyncedDoor.BreakDoor(None, false);
    }
}

// Check if a door matches the given ID
function bool IsDoorMatchingId(OLDoor Door, int DoorId)
{
    if (Door == None) return false;
    return int(Door.Location.X * 7 + Door.Location.Y * 13) == DoorId;
}

// Find a door by its hash ID
function OLDoor FindDoorById(int DoorId)
{
    local OLDoor Door;
    
    foreach DynamicActors(class'OLDoor', Door)
    {
        if (IsDoorMatchingId(Door, DoorId))
            return Door;
    }
    return None;
}

// Apply synced door state - directly rotate the door mesh
// Can't use ForceOpenRatio (not exposed to script), so we rotate DoorMainMesh directly
function ApplyDoorSync()
{
    local rotator DoorRot, TargetRot;
    local float DoorAngleDeg;
    local float InterpSpeed;
    
    if (SyncedDoor == None || SyncDoorOpenRatio < 0.0)
        return;
    
    // Update the door's state variables so the game knows it's open/closed
    SyncedDoor.OpenRatio = SyncDoorOpenRatio;
    SyncedDoor.TargetOpenRatio = SyncDoorOpenRatio;
    
    // Compute target rotation
    DoorAngleDeg = SyncDoorOpenRatio * SyncedDoor.MaxOpenAngle;
    TargetRot = SyncedDoor.DoorMainMesh.Rotation;
    TargetRot.Yaw = int(DoorAngleDeg * (32768.0 / 180.0));
    if (!SyncedDoor.bReverseDirection)
        TargetRot.Yaw = -TargetRot.Yaw;
    
    // Smoothly interpolate toward target
    DoorRot = SyncedDoor.DoorMainMesh.Rotation;
    InterpSpeed = 15.0;  // degrees per second feel
    DoorRot.Yaw = DoorRot.Yaw + int(float(TargetRot.Yaw - DoorRot.Yaw) * FMin(1.0, WorldInfo.DeltaSeconds * InterpSpeed));
    SyncedDoor.DoorMainMesh.SetRotation(DoorRot);
}

function OnCamcorderChange(bool bNowCamcorder, int NewCamState)
{
    if (NewCamState == CurrentCamcorderState && bNowCamcorder == bCurrentCamcorder)
        return;
    
    if (bNowCamcorder != bCurrentCamcorder)
    {
        RemoteHero.bCamcorderDesired = bNowCamcorder;
        if (RemoteHero.CameraMeshShadowProxy != None)
        {
            if (bNowCamcorder)
                RemoteHero.CameraMeshShadowProxy.SetHidden(false);
            else
                SetTimer(0.55, false, 'HideCamcorderProp');
        }
        if (RemoteHero.ShadowProxyRightArmAnimSlot != None)
        {
            if (bNowCamcorder)
            {
                RemoteHero.ShadowProxyRightArmAnimSlot.PlayCustomAnim(
                    bCurrentCrouched ? 'player_crouch_camcorder_raise' : 'player_camcorder_raise',
                    1.0, 0.15, 0.15, false, true);
                SetTimer(0.50, false, 'PlayCamcorderIdleAnim');
            }
            else
            {
                ClearTimer('PlayCamcorderIdleAnim');
                RemoteHero.ShadowProxyRightArmAnimSlot.PlayCustomAnim(
                    bCurrentCrouched ? 'player_crouch_camcorder_lower' : 'player_camcorder_lower',
                    1.0, 0.15, 0.15, false, true);
            }
        }
        bCurrentCamcorder = bNowCamcorder;
    }
    
    if (NewCamState != CurrentCamcorderState)
    {
        CurrentCamcorderState = NewCamState;
        switch (NewCamState)
        {
            case 4:
                ClearTimer('PlayCamcorderIdleAnim');
                ClearTimer('FinishInactiveReload');
                if (RemoteHero.ShadowProxyRightArmAnimSlot != None)
                    RemoteHero.ShadowProxyRightArmAnimSlot.PlayCustomAnim(
                        bCurrentCrouched ? 'player_crouch_camcorder_reload' : 'player_camcorder_reload',
                        1.0, 0.15, 0.05, false, true);
                if (RemoteHero.ShadowProxyLeftArmAnimSlot != None)
                    RemoteHero.ShadowProxyLeftArmAnimSlot.PlayCustomAnim(
                        bCurrentCrouched ? 'player_crouch_camcorder_reload' : 'player_camcorder_reload',
                        1.0, 0.15, 0.4, false, true);
                SetTimer(2.85, false, 'PlayCamcorderIdleAnim');
                break;
            case 5:
                ClearTimer('PlayCamcorderIdleAnim');
                ClearTimer('FinishInactiveReload');
                if (RemoteHero.CameraMeshShadowProxy != None)
                    RemoteHero.CameraMeshShadowProxy.SetHidden(false);
                if (RemoteHero.ShadowProxyRightArmAnimSlot != None)
                    RemoteHero.ShadowProxyRightArmAnimSlot.PlayCustomAnim(
                        bCurrentCrouched ? 'player_crouch_camcorder_reload_inactive' : 'player_camcorder_reload_inactive',
                        1.0, 0.15, 0.05, false, true);
                if (RemoteHero.ShadowProxyLeftArmAnimSlot != None)
                    RemoteHero.ShadowProxyLeftArmAnimSlot.StopCustomAnim(0.15);
                SetTimer(2.85, false, 'FinishInactiveReload');
                break;
            default:
                if (bCurrentCamcorder && NewCamState == 1)
                {
                    ClearTimer('PlayCamcorderIdleAnim');
                    ClearTimer('FinishInactiveReload');
                    PlayCamcorderIdleAnim();
                    if (RemoteHero.ShadowProxyLeftArmAnimSlot != None)
                        RemoteHero.ShadowProxyLeftArmAnimSlot.StopCustomAnim(0.2);
                }
                break;
        }
    }
}

function HideCamcorderProp()
{
    if (RemoteHero != None && RemoteHero.CameraMeshShadowProxy != None)
        RemoteHero.CameraMeshShadowProxy.SetHidden(true);
}

function PlayCamcorderIdleAnim()
{
    if (RemoteHero != None && RemoteHero.ShadowProxyRightArmAnimSlot != None)
        RemoteHero.ShadowProxyRightArmAnimSlot.PlayCustomAnim(
            bCurrentCrouched ? 'player_crouch_camcorder_idle' : 'player_camcorder_idle',
            1.0, 0.05, -1.0, true, true);
}

function FinishInactiveReload()
{
    if (RemoteHero == None) return;
    if (RemoteHero.CameraMeshShadowProxy != None)
        RemoteHero.CameraMeshShadowProxy.SetHidden(true);
    if (RemoteHero.ShadowProxyRightArmAnimSlot != None)
        RemoteHero.ShadowProxyRightArmAnimSlot.StopCustomAnim(0.15);
    if (RemoteHero.ShadowProxyLeftArmAnimSlot != None)
        RemoteHero.ShadowProxyLeftArmAnimSlot.StopCustomAnim(0.15);
}

// Drives idle/movement animations for crouched state
// Ported from original OLTogetherController.UpdateDummyMovementAnim
function UpdateDummyMovementAnim()
{
    local vector FV, FD, SD, VD;
    local float FS, FDt, SDt, YR;
    local name AP;
    
    if (RemoteHero == None || RemoteHero.ShadowProxy == None) return;
    if (WorldInfo.TimeSeconds < AnimLockEndTime) return;
    if (bPlayingSpecialAnim) return;  // Don't override vault/door/etc animations
    
    // Only drive animations for crouched state (standing is handled by anim tree)
    if (!bCurrentCrouched)
    {
        if (LastMovementAnim != 'None')
        {
            LastMovementAnim = 'None';
            if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
                RemoteHero.ShadowProxyFullBodyAnimSlot.StopCustomAnim(0.15);
        }
        // Don't override locomotion mode - let the locomotion handler manage it
        // (LM_Fall for jumping, LM_SpecialMove for vaults, etc.)
        return;
    }
    
    // Crouched - determine animation based on velocity
    FV = RemoteHero.Velocity;
    FV.Z = 0;
    FS = VSize(FV);
    
    if (FS < 20.0)
    {
        // Standing still - play crouch lean or idle (from original line 945)
        if (CurrentLeanDir == 1)
            AP = 'player_crouch_lean_left';
        else if (CurrentLeanDir == 2)
            AP = 'player_crouch_lean_right';
        else
            AP = 'player_crouch_idle';
    }
    else
    {
        // Moving - determine direction
        // Yaw is in Unreal units (0-65536 = full circle), convert to radians
        YR = RemoteHero.Rotation.Yaw * (3.1415927 / 32768.0);
        FD.X = Cos(YR); FD.Y = Sin(YR); FD.Z = 0;
        SD.X = Cos(YR + 1.5707963); SD.Y = Sin(YR + 1.5707963); SD.Z = 0;
        VD = FV / FS;
        FDt = (VD.X * FD.X) + (VD.Y * FD.Y);
        SDt = (VD.X * SD.X) + (VD.Y * SD.Y);
        
        if (FDt > 0.7)
            AP = 'player_crouch_forward';
        else if (FDt < -0.7)
            AP = 'player_crouch_backward';
        else if (SDt > 0.0)
            AP = 'player_crouch_strafe_right';
        else
            AP = 'player_crouch_strafe_left';
    }
    
    // Only play if animation changed
    if (AP != LastMovementAnim)
    {
        LastMovementAnim = AP;
        if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
        {
            `log("[ANIM_IDLE] Played:" @ AP @ "Velocity:" @ VSize(RemoteHero.Velocity) @ "bPlayingSpecial:" @ bPlayingSpecialAnim @ "Time:" @ WorldInfo.TimeSeconds);
            RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim(AP, 1.0, 0.2, 0.0, true, false);
        }
    }
}

DefaultProperties
{
    bAlwaysTick=true
    TeleportDistThreshold=300.0
    InterpSpeed=25.0
    bHasState=false
    bPlayingSpecialAnim=false
    bPositionLocked=false
    bLockRotation=true
    bWaitingForInstantVault=false
    PendingVaultMoveType=0
    LastPlayedSpecialMove=0
    CurrentLocomotionMode=0
    CurrentSpecialMove=0
    bCurrentCrouched=false
    bCurrentCamcorder=false
    CurrentCamcorderState=0
    bPlayingCrouchTransition=false
    CrouchTransitionStartTime=0.0
    CrouchTransitionDuration=0.0
    AnimLockEndTime=0.0
    LastMovementAnim=None
    LastEndedSpecialMove=0
    LastSpecialMoveEndTime=0.0
    SyncDoorId=0
    SyncDoorOpenRatio=-1.0
    SyncedDoor=None
    SyncedDoorOpenRatio=0.0
}
