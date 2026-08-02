class OLTogetherSettings extends Object
    config(MPSettings);

// Persisted multiplayer / privacy preferences. Everything here is written to
// MPSettings.ini via SaveConfig() and applied live from the settings menu.

// Pause the game when the window loses focus. Off by default because the mod is
// multiplayer and stopping the world would desync remote players.
var config bool bPauseOnLossFocus;

// Hide the floating name tags above other players.
var config bool bHidePlayerNames;

// Silence all incoming voice at once.
var config bool bMuteEveryone;

// Proximity voice chat settings
var config float VoiceProximityNear;
var config float VoiceProximityFar;

// Silence all remote players (multi-player relay design).
var config bool bMuteRemotePlayer;

// Fade nearby players when very close (avoids view collision).
var config bool bFadeNearbyPlayers;

// Push-to-talk input mode.
var config bool bPushToTalk;

// Automatically re-establish the relay connection after a drop.
var config bool bAutoReconnect;

// Delay, in seconds, before an automatic reconnect attempt.
var config float ReconnectDelay;

// Selected player model in the Models tab.
var config int SelectedModelIndex;

// Set once so first-run defaults below are only seeded a single time.
var config bool bConfigured;

const MODEL_Default = 0;
const MODEL_COUNT   = 11;

function SeedDefaults()
{
    if (bConfigured)
    {
        if (VoiceProximityFar == 0.0)
        {
            VoiceProximityNear = 800.0;
            VoiceProximityFar = 2500.0;
            SaveConfig();
        }
        return;
    }

    bPauseOnLossFocus  = false;
    bHidePlayerNames   = false;
    bMuteEveryone      = false;
    VoiceProximityNear = 800.0;
    VoiceProximityFar  = 2500.0;
    bMuteRemotePlayer  = false;
    bFadeNearbyPlayers = false;
    bPushToTalk        = false;
    bAutoReconnect     = true;
    ReconnectDelay     = 5.0;
    SelectedModelIndex = MODEL_Default;
    bConfigured        = true;

    SaveConfig();
}

defaultproperties
{
    bAutoReconnect=true
    ReconnectDelay=5.0
}
