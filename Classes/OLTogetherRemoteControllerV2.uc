// High-performance remote controller with adaptive interpolation and predictive dead reckoning
class OLTogetherRemoteControllerV2 extends AIController;

var OLTogetherRemoteHero RemoteHero;
var OLTogetherNetworkState NetworkState;

// Interpolation state
var float TeleportDistThreshold;
var float InterpSpeed;
var float RotInterpSpeed;
var bool bHasState;

// Current rendered state
var int CurrentLocomotionMode;
var int CurrentSpecialMove;
var int CurrentDoorDir;
var int CurrentLeanDir;
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

// Crouch transition tracking
var bool bPlayingCrouchTransition;
var float CrouchTransitionStartTime;
var float CrouchTransitionDuration;
var float AnimLockEndTime;  // From original: prevents idle system from overriding transition
var name LastMovementAnim;  // From original: tracks current movement anim to avoid redundant swaps

// SM re-trigger prevention
var int LastEndedSpecialMove;
var float LastSpecialMoveEndTime;

// Door sync state
var int SyncDoorId;           // Hash of host's active door location
var float SyncDoorOpenRatio;  // Host's active door open ratio (-1 = no door)
var OLDoor SyncedDoor;        // Cached reference to the synced door
var float SyncedDoorOpenRatio; // Current interpolated open ratio

// Prediction state
var vector PredictedLocation;
var int PredictedYaw;
var int LastReceivedYaw;
var float LastStateUpdateTime;

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
    
    if (bPlayingSpecialAnim)
        EndSpecialMoveAnim();
    
    // Default blend times (from OLHero::PlayFullBodyAnim)
    BlendIn = 0.25;
    BlendOut = 0.25;
    AnimDuration = 1.0;
    bPositionLocked = false;
    bLockRotation = true;
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
    `log("[ANIM_BEFORE] bPlayingSpecialAnim:" @ bPlayingSpecialAnim @ "CurrentSM:" @ CurrentSpecialMove @ "Time:" @ WorldInfo.TimeSeconds);
    RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim(AnimName, 1.0, BlendIn, BlendOut, false, false);
    `log("[ANIM_PLAY] Played:" @ AnimName @ "BlendIn:" @ BlendIn @ "BlendOut:" @ BlendOut @ "Duration:" @ AnimDuration @ "SM:" @ MoveType @ "Time:" @ WorldInfo.TimeSeconds);
    bPlayingSpecialAnim = true;
    SpecialAnimStartTime = WorldInfo.TimeSeconds;
    SpecialAnimDuration = AnimDuration;
    CurrentSpecialMove = MoveType;
    LastPlayedSpecialMove = MoveType;
}

function EndSpecialMoveAnim()
{
    if (RemoteHero == None) return;
    
    `log("[ANIM_END] Stopping anim, SM:" @ CurrentSpecialMove @ "was playing for:" @ (WorldInfo.TimeSeconds - SpecialAnimStartTime) @ "Time:" @ WorldInfo.TimeSeconds);
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
        RemoteHero.ShadowProxyFullBodyAnimSlot.StopCustomAnim(0.1);
}

event Tick(float DeltaTime)
{
    local float HostTime, RenderTime;
    local OLTogetherNetworkState.CompactState Before, After, Desired;
    local float Alpha, MoveDist, ElapsedAnimTime;
    local vector MoveDelta, ProjectedLoc, InterpLoc;
    local rotator DesiredRot, InterpRot;
    local bool bHostEndedSpecialMove, bIsVault;
    local int RotDiff;
    
    if (!bHasState || NetworkState == None || NetworkState.StateBuffer.Length == 0 || RemoteHero == None)
        return;
    
    HostTime = GetHostTime();
    RenderTime = HostTime - NetworkState.AdaptiveDelay;  // Use adaptive delay instead of fixed
    
    if (!FindBracketingStates(RenderTime, Before, After, Alpha))
        return;
    
    // Hermite interpolation for smoother movement (uses velocity for curved path)
    Desired.Location = NetworkState.HermiteInterp(Before.Location, Before.Velocity, After.Location, After.Velocity, Alpha);
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
        // SM 14 (GrabLedgeFromGround) and SM 15 (GrabLedgeFromAir) need to stay active
        // until locomotion mode transitions to LM_LedgeHang (4), not just duration expiry
        if (CurrentSpecialMove == 14 || CurrentSpecialMove == 15)
        {
            bHostEndedSpecialMove = (Desired.LocomotionMode == 4);
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
            // For ledge grab SMs, immediately start ledge idle to avoid default pose gap
            if (CurrentSpecialMove == 14 || CurrentSpecialMove == 15)
            {
                `log("[ANIM_LEDGE_GRAB_END] SM:" @ CurrentSpecialMove @ "Transitioning to ledge idle Time:" @ WorldInfo.TimeSeconds);
                if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
                    RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_idle', 1.0, 0.05, 0.0, true, false);
            }
            EndSpecialMoveAnim();
            PredictedLocation = RemoteHero.Location;
            PredictedYaw = RemoteHero.Rotation.Yaw;
            return;
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
    DesiredRot.Yaw = Desired.Yaw;
    DesiredRot.Pitch = 0;
    DesiredRot.Roll = 0;
    
    // Movement interpolation with teleport threshold
    MoveDelta = Desired.Location - RemoteHero.Location;
    MoveDelta.Z = 0;
    MoveDist = VSize(MoveDelta);
    
    if (MoveDist > TeleportDistThreshold)
    {
        // Large distance - teleport
        RemoteHero.SetLocation(Desired.Location);
        PredictedLocation = Desired.Location;
        PredictedYaw = Desired.Yaw;
    }
    else
    {
        // Smooth interpolation directly toward desired network position
        InterpLoc = VInterpTo(RemoteHero.Location, Desired.Location, DeltaTime, InterpSpeed);
        RemoteHero.SetLocation(InterpLoc);
        PredictedLocation = InterpLoc;
    }
    
    // Adaptive rotation interpolation - fast flicks snap, slow turns smooth
    // Skip if position locking already set the rotation (door/vault/climb)
    // Also skip during ledge locomotion - ledge system/animation controls rotation
    if (!bPositionLocked && CurrentLocomotionMode != 4 && CurrentLocomotionMode != 5)
    {
        RotDiff = Abs(Desired.Yaw - PredictedYaw);
        if (RotDiff > 32768)
            RotDiff = 65536 - RotDiff;
        
        if (RotDiff > 10922)  // ~60 degrees
        {
            // Fast flick - snap immediately
            RemoteHero.SetRotation(DesiredRot);
            PredictedYaw = Desired.Yaw;
        }
        else
        {
            // Slow turn - interpolate smoothly
            InterpRot = RInterpTo(RemoteHero.Rotation, DesiredRot, DeltaTime, RotInterpSpeed);
            RemoteHero.SetRotation(InterpRot);
            PredictedYaw = InterpRot.Yaw;
        }
    }
    
    RemoteHero.Velocity = Desired.Velocity;
    RemoteHero.Acceleration = Desired.Velocity;
    
    // Update locomotion mode
    if (Desired.LocomotionMode != CurrentLocomotionMode)
    {
        switch (Desired.LocomotionMode)
        {
            case 0:  RemoteHero.LocomotionMode = LM_Walk; break;
            case 1:  RemoteHero.LocomotionMode = LM_Fall; break;
            case 2:  RemoteHero.LocomotionMode = LM_SpecialMove; break;
            case 3:  RemoteHero.LocomotionMode = LM_Ladder; break;
            case 4:  RemoteHero.LocomotionMode = LM_LedgeHang; break;
            case 5:  RemoteHero.LocomotionMode = LM_LedgeWalk; break;
            case 6:  RemoteHero.LocomotionMode = LM_Squeeze; break;
            case 7:  RemoteHero.LocomotionMode = LM_Door; break;
            case 8:  RemoteHero.LocomotionMode = LM_Locker; break;
            case 9:  RemoteHero.LocomotionMode = LM_Cinematic; break;
            case 10: RemoteHero.LocomotionMode = LM_Bed; break;
            case 11: RemoteHero.LocomotionMode = LM_LookBack; break;
            case 12: RemoteHero.LocomotionMode = LM_Struggle; break;
            case 13: RemoteHero.LocomotionMode = LM_Grabbed; break;
            case 14: RemoteHero.LocomotionMode = LM_Pushing; break;
            case 15: RemoteHero.LocomotionMode = LM_ContextualLean; break;
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
    
    // Ledge walk move animations - play shimmy anims based on velocity direction
    // During LM_LedgeHang/LM_LedgeWalk, the ledge system drives position; anim is visual only
    // No idle - just freeze the anim when stationary, resume when moving
    if ((CurrentLocomotionMode == 4 || CurrentLocomotionMode == 5) && !bPlayingSpecialAnim)
    {
        if (RemoteHero.ShadowProxyFullBodyAnimSlot != None)
        {
            if (VSize(RemoteHero.Velocity) > 50.0)
            {
                // Determine shimmy direction from velocity relative to pawn facing
                if (RemoteHero.Velocity.X * -Sin(RemoteHero.Rotation.Yaw * 3.1415927 / 32768.0)
                    + RemoteHero.Velocity.Y * Cos(RemoteHero.Rotation.Yaw * 3.1415927 / 32768.0) > 0.0)
                {
                    if (LastMovementAnim != 'player_ledge_walk_move_right')
                    {
                        LastMovementAnim = 'player_ledge_walk_move_right';
                        RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_walk_move_right', 1.0, 0.1, 0.0, true, false);
                    }
                    else
                    {
                        // Resume playback rate
                        if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                            RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 1.0;
                    }
                }
                else
                {
                    if (LastMovementAnim != 'player_ledge_walk_move_left')
                    {
                        LastMovementAnim = 'player_ledge_walk_move_left';
                        RemoteHero.ShadowProxyFullBodyAnimSlot.PlayCustomAnim('player_ledge_walk_move_left', 1.0, 0.1, 0.0, true, false);
                    }
                    else
                    {
                        // Resume playback rate
                        if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                            RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 1.0;
                    }
                }
            }
            else
            {
                // Frozen - pause the animation in place
                if (RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq() != None)
                    RemoteHero.ShadowProxyFullBodyAnimSlot.GetCustomAnimNodeSeq().Rate = 0.0;
            }
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
    
    CurrentDoorDir = Desired.DoorDir;
    CurrentExtraData = Desired.ExtraData;
    CurrentExtraKind = Desired.ExtraKind;
    CurrentHealth = Desired.Health;
    
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
    RotInterpSpeed=100.0
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
