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
// Improved with better smoothing and burst detection
function UpdateJitterMetrics(float PacketTime)
{
    local float Jitter, TimeDelta;
    
    if (Metrics.LastPacketTime > 0.0)
    {
        TimeDelta = PacketTime - Metrics.LastPacketTime;
        
        // Expected time between packets at 30Hz = 0.033s
        Jitter = Abs(TimeDelta - 0.033);
        
        // Detect packet bursts (multiple packets in < 10ms)
        // If burst, use smaller jitter weight to not over-correct
        if (TimeDelta < 0.01)
            Jitter = Jitter * 0.3;
        
        // Exponential moving average for jitter with asymmetric weighting
        // React faster to jitter increases, slower to decreases for stability
        if (Metrics.TotalPacketsReceived > 0)
        {
            if (Jitter > Metrics.AverageJitter)
                Metrics.AverageJitter = Metrics.AverageJitter + (Jitter - Metrics.AverageJitter) * 0.3;  // Fast reaction to worse
            else
                Metrics.AverageJitter = Metrics.AverageJitter + (Jitter - Metrics.AverageJitter) * 0.05;  // Slow recovery to better
        }
        else
            Metrics.AverageJitter = Jitter;
    }
    
    Metrics.LastPacketTime = PacketTime;
    Metrics.TotalPacketsReceived++;
    
    // Adaptive delay: base + (jitter * safety factor with cap)
    // Clamp jitter factor to prevent runaway delay
    AdaptiveDelay = FClamp(MinDelay + FMin(Metrics.AverageJitter * 3.0, 0.05), MinDelay, MaxDelay);
}

// Hermite interpolation for smoother movement (considers velocity for curve)
// Now uses actual timestep between states instead of hardcoded 0.033
function vector HermiteInterp(vector P0, vector V0, vector P1, vector V1, float Alpha, float DeltaTime)
{
    local float Alpha2, Alpha3;
    local vector Result;
    
    Alpha2 = Alpha * Alpha;
    Alpha3 = Alpha2 * Alpha;
    
    // Hermite basis functions - scale velocity by actual timestep for correct curve magnitude
    Result = P0 * (2.0 * Alpha3 - 3.0 * Alpha2 + 1.0)
           + V0 * (Alpha3 - 2.0 * Alpha2 + Alpha) * DeltaTime
           + P1 * (-2.0 * Alpha3 + 3.0 * Alpha2)
           + V1 * (Alpha3 - Alpha2) * DeltaTime;
    
    return Result;
}

// Predictive dead reckoning with acceleration and smooth deceleration
function CompactState PredictState(CompactState LastState, float DeltaTime)
{
    local CompactState Predicted;
    local float Speed, DampingFactor;
    
    Predicted = LastState;
    
    // Extrapolate position with velocity
    Predicted.Location.X += LastState.Velocity.X * DeltaTime;
    Predicted.Location.Y += LastState.Velocity.Y * DeltaTime;
    // Don't extrapolate Z - causes floating/sinking
    
    // Smooth velocity damping model:
    // Characters naturally decelerate when not actively moving
    // Use exponential decay for realistic slowdown
    Speed = Sqrt(LastState.Velocity.X * LastState.Velocity.X + LastState.Velocity.Y * LastState.Velocity.Y);
    if (Speed > 10.0)
    {
        // Exponential decay: v(t) = v0 * e^(-k*t)
        // k=2.0 gives ~86% reduction over 1 second
        DampingFactor = Exp(-2.0 * DeltaTime);
        Predicted.Velocity.X *= DampingFactor;
        Predicted.Velocity.Y *= DampingFactor;
    }
    else
    {
        // Nearly stopped - zero out to avoid micro-drift
        Predicted.Velocity.X = 0;
        Predicted.Velocity.Y = 0;
    }
    
    return Predicted;
}

// Smooth cubic interpolation for rotation (prevents gimbal lock and jitter)
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
    
    // Smooth-step interpolation: 3α² - 2α³ (smoother than linear)
    // This gives natural acceleration/deceleration to rotation changes
    SmoothAlpha = Alpha * Alpha * (3.0 - 2.0 * Alpha);
    
    return (R0 + int(float(Delta) * SmoothAlpha)) & 65535;
}

DefaultProperties
{
    MinDelay=0.02           // 20ms minimum delay (was 10ms - gives more buffer room)
    MaxDelay=0.1            // 100ms maximum delay
    AdaptiveDelay=0.033     // Start at one packet interval
    JitterWeight=0.1        // Slow adaptation to jitter changes
    bHasReceivedState=false
}
