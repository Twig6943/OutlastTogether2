// High-performance network state management with adaptive interpolation, delta encoding, and jitter buffer
class OLTogetherNetworkState extends Object;

struct CompactState
{
    var float TimeStamp;
    var vector Location;
    var vector Velocity;
    var int Yaw;              // Only yaw matters for character rotation
    var byte PackedFlags;     // Crouch(1) | Camcorder(2) | Running(4) | PlayingAnim(8) | Reserved(16-128)
    var byte LocomotionMode;
    var byte SpecialMove;
    var byte CamcorderState;
    var byte Health;
    var byte DoorDir;
    var byte LeanDir;
    var byte ExtraData;
    var byte ExtraKind;
    var float DoorRatio;      // Door hold open ratio [0,1]
};

struct DeltaState
{
    var bool bHasLocation;
    var bool bHasVelocity;
    var bool bHasYaw;
    var bool bHasFlags;
    var bool bHasLocomotion;
    var bool bHasSpecialMove;
    var bool bHasCamcorder;
    var bool bHasHealth;
    var bool bHasDoor;
    var bool bHasLean;
    var bool bHasExtra;
    
    var vector Location;
    var vector Velocity;
    var int Yaw;
    var byte PackedFlags;
    var byte LocomotionMode;
    var byte SpecialMove;
    var byte CamcorderState;
    var byte Health;
    var byte DoorDir;
    var byte LeanDir;
    var byte ExtraData;
    var byte ExtraKind;
};

struct JitterBufferMetrics
{
    var float AverageJitter;        // Running average of packet timing variance
    var float PacketLossRate;       // Percentage of lost packets
    var float AverageLatency;       // One-way latency estimate
    var int TotalPacketsReceived;
    var int TotalPacketsLost;
    var float LastPacketTime;
    var int LastSequenceNumber;
};

var array<CompactState> StateBuffer;
var CompactState LastReceivedState;
var CompactState PredictedState;
var JitterBufferMetrics Metrics;

var float AdaptiveDelay;           // Dynamic interpolation delay based on jitter
var float MinDelay;                // Minimum interpolation delay (10ms)
var float MaxDelay;                // Maximum interpolation delay (100ms)
var float JitterWeight;            // Weight for jitter calculation (0.1 = slow adaptation)

var float ServerTimeOffset;
var bool bHasReceivedState;

// High-performance state compression
function string EncodeStateDelta(CompactState Current, CompactState Previous)
{
    local DeltaState Delta;
    local string Result;
    local int DeltaFlags;
    
    DeltaFlags = 0;
    
    // Check what changed since last packet
    if (VSize(Current.Location - Previous.Location) > 0.1)
    {
        Delta.bHasLocation = true;
        Delta.Location = Current.Location;
        DeltaFlags = DeltaFlags | 1;
    }
    
    if (VSize(Current.Velocity - Previous.Velocity) > 1.0)
    {
        Delta.bHasVelocity = true;
        Delta.Velocity = Current.Velocity;
        DeltaFlags = DeltaFlags | 2;
    }
    
    if (Abs(Current.Yaw - Previous.Yaw) > 100)
    {
        Delta.bHasYaw = true;
        Delta.Yaw = Current.Yaw;
        DeltaFlags = DeltaFlags | 4;
    }
    
    if (Current.PackedFlags != Previous.PackedFlags)
    {
        Delta.bHasFlags = true;
        Delta.PackedFlags = Current.PackedFlags;
        DeltaFlags = DeltaFlags | 8;
    }
    
    if (Current.LocomotionMode != Previous.LocomotionMode)
    {
        Delta.bHasLocomotion = true;
        Delta.LocomotionMode = Current.LocomotionMode;
        DeltaFlags = DeltaFlags | 16;
    }
    
    if (Current.SpecialMove != Previous.SpecialMove)
    {
        Delta.bHasSpecialMove = true;
        Delta.SpecialMove = Current.SpecialMove;
        DeltaFlags = DeltaFlags | 32;
    }
    
    if (Current.CamcorderState != Previous.CamcorderState)
    {
        Delta.bHasCamcorder = true;
        Delta.CamcorderState = Current.CamcorderState;
        DeltaFlags = DeltaFlags | 64;
    }
    
    if (Current.Health != Previous.Health)
    {
        Delta.bHasHealth = true;
        Delta.Health = Current.Health;
        DeltaFlags = DeltaFlags | 128;
    }
    
    if (Current.DoorDir != Previous.DoorDir)
    {
        Delta.bHasDoor = true;
        Delta.DoorDir = Current.DoorDir;
        DeltaFlags = DeltaFlags | 256;
    }
    
    if (Current.LeanDir != Previous.LeanDir)
    {
        Delta.bHasLean = true;
        Delta.LeanDir = Current.LeanDir;
        DeltaFlags = DeltaFlags | 512;
    }
    
    if (Current.ExtraData != Previous.ExtraData || Current.ExtraKind != Previous.ExtraKind)
    {
        Delta.bHasExtra = true;
        Delta.ExtraData = Current.ExtraData;
        Delta.ExtraKind = Current.ExtraKind;
        DeltaFlags = DeltaFlags | 1024;
    }
    
    // Build compact packet: DLT,timestamp,flags,data...
    Result = "DLT," $ Current.TimeStamp $ "," $ DeltaFlags;
    
    if (Delta.bHasLocation)
        Result = Result $ "," $ int(Delta.Location.X) $ "," $ int(Delta.Location.Y) $ "," $ int(Delta.Location.Z);
    if (Delta.bHasVelocity)
        Result = Result $ "," $ int(Delta.Velocity.X) $ "," $ int(Delta.Velocity.Y) $ "," $ int(Delta.Velocity.Z);
    if (Delta.bHasYaw)
        Result = Result $ "," $ Delta.Yaw;
    if (Delta.bHasFlags)
        Result = Result $ "," $ Delta.PackedFlags;
    if (Delta.bHasLocomotion)
        Result = Result $ "," $ Delta.LocomotionMode;
    if (Delta.bHasSpecialMove)
        Result = Result $ "," $ Delta.SpecialMove;
    if (Delta.bHasCamcorder)
        Result = Result $ "," $ Delta.CamcorderState;
    if (Delta.bHasHealth)
        Result = Result $ "," $ Delta.Health;
    if (Delta.bHasDoor)
        Result = Result $ "," $ Delta.DoorDir;
    if (Delta.bHasLean)
        Result = Result $ "," $ Delta.LeanDir;
    if (Delta.bHasExtra)
        Result = Result $ "," $ Delta.ExtraData $ "," $ Delta.ExtraKind;
    
    return Result;
}

function CompactState DecodeStateDelta(string Packet, CompactState Baseline)
{
    local array<string> Fields;
    local CompactState Result;
    local int DeltaFlags, FieldIdx;
    
    Fields = SplitString(Packet, ",", true);
    if (Fields.Length < 3 || Fields[0] != "DLT")
        return Baseline;
    
    Result = Baseline;
    Result.TimeStamp = float(Fields[1]);
    DeltaFlags = int(Fields[2]);
    FieldIdx = 3;
    
    if ((DeltaFlags & 1) != 0 && FieldIdx + 2 < Fields.Length)
    {
        Result.Location.X = float(Fields[FieldIdx++]);
        Result.Location.Y = float(Fields[FieldIdx++]);
        Result.Location.Z = float(Fields[FieldIdx++]);
    }
    
    if ((DeltaFlags & 2) != 0 && FieldIdx + 2 < Fields.Length)
    {
        Result.Velocity.X = float(Fields[FieldIdx++]);
        Result.Velocity.Y = float(Fields[FieldIdx++]);
        Result.Velocity.Z = float(Fields[FieldIdx++]);
    }
    
    if ((DeltaFlags & 4) != 0 && FieldIdx < Fields.Length)
        Result.Yaw = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 8) != 0 && FieldIdx < Fields.Length)
        Result.PackedFlags = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 16) != 0 && FieldIdx < Fields.Length)
        Result.LocomotionMode = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 32) != 0 && FieldIdx < Fields.Length)
        Result.SpecialMove = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 64) != 0 && FieldIdx < Fields.Length)
        Result.CamcorderState = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 128) != 0 && FieldIdx < Fields.Length)
        Result.Health = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 256) != 0 && FieldIdx < Fields.Length)
        Result.DoorDir = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 512) != 0 && FieldIdx < Fields.Length)
        Result.LeanDir = int(Fields[FieldIdx++]);
    
    if ((DeltaFlags & 1024) != 0 && FieldIdx + 1 < Fields.Length)
    {
        Result.ExtraData = int(Fields[FieldIdx++]);
        Result.ExtraKind = int(Fields[FieldIdx++]);
    }
    
    return Result;
}

// Adaptive jitter buffer - dynamically adjusts delay based on network conditions
function UpdateJitterMetrics(float PacketTime)
{
    local float Jitter, TimeDelta;
    
    if (Metrics.LastPacketTime > 0.0)
    {
        TimeDelta = PacketTime - Metrics.LastPacketTime;
        
        // Expected time between packets (33ms)
        Jitter = Abs(TimeDelta - 0.033);
        
        // Exponential moving average for jitter
        if (Metrics.TotalPacketsReceived > 0)
            Metrics.AverageJitter = (Metrics.AverageJitter * (1.0 - JitterWeight)) + (Jitter * JitterWeight);
        else
            Metrics.AverageJitter = Jitter;
    }
    
    Metrics.LastPacketTime = PacketTime;
    Metrics.TotalPacketsReceived++;
    
    // Adaptive delay: base + (jitter * safety factor)
    AdaptiveDelay = FClamp(MinDelay + (Metrics.AverageJitter * 2.0), MinDelay, MaxDelay);
}

// Hermite interpolation for smoother movement (considers velocity for curve)
function vector HermiteInterp(vector P0, vector V0, vector P1, vector V1, float Alpha)
{
    local float Alpha2, Alpha3;
    local vector Result;
    
    Alpha2 = Alpha * Alpha;
    Alpha3 = Alpha2 * Alpha;
    
    // Hermite basis functions
    Result = P0 * (2.0 * Alpha3 - 3.0 * Alpha2 + 1.0)
           + V0 * (Alpha3 - 2.0 * Alpha2 + Alpha) * 0.033  // Scale by timestep
           + P1 * (-2.0 * Alpha3 + 3.0 * Alpha2)
           + V1 * (Alpha3 - Alpha2) * 0.033;
    
    return Result;
}

// Predictive dead reckoning with acceleration
function CompactState PredictState(CompactState LastState, float DeltaTime)
{
    local CompactState Predicted;
    local vector AccelDir;
    local float Speed;
    
    Predicted = LastState;
    
    // Extrapolate position with velocity
    Predicted.Location.X += LastState.Velocity.X * DeltaTime;
    Predicted.Location.Y += LastState.Velocity.Y * DeltaTime;
    // Don't extrapolate Z - causes floating/sinking
    
    // Predict velocity damping (characters slow down when not moving)
    Speed = VSize(LastState.Velocity);
    if (Speed > 50.0)
    {
        // Apply slight damping for more accurate prediction
        Predicted.Velocity = LastState.Velocity * (1.0 - DeltaTime * 0.5);
    }
    
    return Predicted;
}

// Cubic interpolation for rotation (prevents gimbal lock issues)
function int CubicRotationInterp(int R0, int R1, float Alpha)
{
    local int Delta;
    local float SmoothAlpha;
    
    Delta = R1 - R0;
    
    // Handle rotation wrap-around
    if (Delta > 32768)
        Delta -= 65536;
    else if (Delta < -32768)
        Delta += 65536;
    
    // Cubic ease-in-out for smoother rotation
    if (Alpha < 0.5)
        SmoothAlpha = 2.0 * Alpha * Alpha;
    else
        SmoothAlpha = 1.0 - 2.0 * (1.0 - Alpha) * (1.0 - Alpha);
    
    return (R0 + int(float(Delta) * SmoothAlpha)) & 65535;
}

DefaultProperties
{
    MinDelay=0.01           // 10ms minimum delay
    MaxDelay=0.1            // 100ms maximum delay
    AdaptiveDelay=0.03      // Start at 30ms
    JitterWeight=0.1        // Slow adaptation to jitter changes
    bHasReceivedState=false
}
