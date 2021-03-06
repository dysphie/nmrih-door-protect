#include <sdkhooks>
#include <vscript_proxy>

#define PLUGIN_DESCRIPTION "Prevents doors from being blocked by players, zombies and props"
#define PLUGIN_VERSION     "1.0.3"

#define MAXPLAYERS_NMRIH 9
#define MAX_EDICTS       2048

enum /* PropDoorState */
{
	DOOR_STATE_CLOSED = 0,
	DOOR_STATE_OPENING,
	DOOR_STATE_OPEN,
	DOOR_STATE_CLOSING,
	DOOR_STATE_AJAR,
};

enum /* FuncDoorState */
{
	TS_AT_TOP,
	TS_AT_BOTTOM,
	TS_GOING_UP,
	TS_GOING_DOWN
};

// Initial timer used by idle ghost doors to return to solid in X seconds
Handle timerUnghost[MAX_EDICTS + 1];

// Repeating timer used by ghost doors that failed to revert to normal 3 seconds after becoming idle
Handle timerUnghostExtended[MAX_EDICTS + 1];

// Repeating timer used by moving doors to check if they're behind schedule
Handle timerCheckTravelTime[MAX_EDICTS + 1];

// Whether this entity index is a ghost door
bool ghostDoor[MAX_EDICTS + 1];

// Number of times this door has been +use'd while moving
int numDirChanges[MAX_EDICTS + 1];

// Next time the player is allowed to +use a door
float nextDoorUseTime[MAX_EDICTS + 1][MAXPLAYERS_NMRIH + 1];

// True if the plugin was loaded late
bool lateloaded;

// Used by trace enumerators to determine if a door is blocked
bool _traceResult;

ConVar cvFailOpenLimit;
ConVar cvGhostTime;
ConVar cvUseRate;
ConVar cvStuckTime;
ConVar cvTransColor;

public Plugin myinfo =
{
	name        = "Door Grief Protection",
	author      = "Dysphie",
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
	url         = "https://github.com/dysphie/nmrih-door-protect"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	lateloaded = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	cvUseRate = CreateConVar("sm_door_use_rate", "0.3",
	                         "Players can +use doors 1 time per this many seconds",
	                         _, true, 0.1, true, 1.0);

	cvFailOpenLimit = CreateConVar("sm_door_max_use_count", "4",
	                               "A door will become a ghost door if it's prevented from opening via +use this many times",
	                               _, true, 0.0);

	cvStuckTime = CreateConVar("sm_door_max_block_seconds", "1.5",
	                           "A door will become a ghost door if it's blocked by an object for this many seconds",
	                           _, true, 0.0);

	cvGhostTime = CreateConVar("sm_ghost_door_revert_after_seconds", "4",
	                           "A ghost door will try to return to normal this many seconds after becoming fully opened/closed",
	                           _, true, 0.0);

	cvTransColor = CreateConVar("sm_ghost_door_opacity", "120",
	                            "Transparency value for ghost doors",
	                            _, true, 0.0, true, 255.0);

	CreateConVar("doorprotect_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION,
	             FCVAR_SPONLY | FCVAR_NOTIFY | FCVAR_DONTRECORD);

	AutoExecConfig(true, "plugin.doorprotect");

	// Collect entities spawned before we loaded in
	if (lateloaded)
	{
		int e = -1;
		while ((e = FindEntityByClassname(e, "prop_door_rotating")) != -1)
		{
			OnDoorCreated(e, true);
		}

		e = -1;
		while ((e = FindEntityByClassname(e, "func_door_rotating")) != -1)
		{
			OnDoorCreated(e, false);
		}
	}

	HookEntityOutput("prop_door_rotating", "OnOpen", OnDoorStartMoving);
	HookEntityOutput("prop_door_rotating", "OnClose", OnDoorStartMoving);
	HookEntityOutput("prop_door_rotating", "OnFullyClosed", OnDoorStopMoving);
	HookEntityOutput("prop_door_rotating", "OnFullyOpen", OnDoorStopMoving);

	HookEntityOutput("func_door_rotating", "OnOpen", OnDoorStartMoving);
	HookEntityOutput("func_door_rotating", "OnClose", OnDoorStartMoving);
	HookEntityOutput("func_door_rotating", "OnFullyClosed", OnDoorStopMoving);
	HookEntityOutput("func_door_rotating", "OnFullyOpen", OnDoorStopMoving);
}

// Reset +use cooldown for a given client index
public void OnClientConnected(int client)
{
	for (int i; i < sizeof(nextDoorUseTime); i++)
	{
		nextDoorUseTime[i][client] = 0.0;
	}
}

// When a door stops moving, we check whether it's a ghost door
// If it is, we wait 3 seconds and try to restore its normal behavior
public Action OnDoorStopMoving(const char[] output, int door, int activator, float delay)
{
	delete timerCheckTravelTime[door];

	if (ghostDoor[door])
	{
		timerUnghost[door] = CreateTimer(cvGhostTime.FloatValue, Timer_BeginUndoBecomeGhost,
		                                 EntIndexToEntRef(door), TIMER_FLAG_NO_MAPCHANGE);
	}

	return Plugin_Continue;
}

Action Timer_BeginUndoBecomeGhost(Handle timer, int doorRef)
{
	int door = EntRefToEntIndex(doorRef);
	if (IsValidEntity(door))
	{
		TryUndoBecomeGhost(door);
	}

	return Plugin_Continue;
}

// Tries to turn a ghost door into a normal door. If a player is in the way,
// the action is postponed indefinitely until we aren't colliding with them
void TryUndoBecomeGhost(int door)
{
	if (!IsDoorTouchingPlayers(door))
	{
		UndoGhost(door);
		return;
	}

	// Continue checking every half a second if players have left our hull
	delete timerUnghostExtended[door];
	timerUnghostExtended[door] = CreateTimer(0.5, Timer_TickUndoBecomeGhost,
	                                         EntIndexToEntRef(door), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_TickUndoBecomeGhost(Handle timer, int doorRef)
{
	int door = EntRefToEntIndex(doorRef);
	if (door != -1 && !IsDoorTouchingPlayers(door))
	{
		// It's finally safe to become solid again
		UndoGhost(door);
		timerUnghostExtended[door] = null;
		numDirChanges[door]        = 0;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

// When a door starts moving we need to constantly check whether it's keeping up with the expected travel time
public Action OnDoorStartMoving(const char[] output, int door, int activator, float delay)
{
	if (timerCheckTravelTime[door])
	{
		return Plugin_Continue;
	}

	DataPack data;
	timerCheckTravelTime[door] = CreateDataTimer(0.1, OnDoorThink, data, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	data.WriteCell(EntIndexToEntRef(door));
	data.WriteFloat(GetGameTime());  // start time
	return Plugin_Continue;
}

// If a door is behind schedule for too long (cvStuckTime), it turns into a ghost door
public Action OnDoorThink(Handle timer, DataPack data)
{
	data.Reset();

	int door = EntRefToEntIndex(data.ReadCell());
	if (door == -1)
	{
		return Plugin_Stop;
	}

	float startMovingTime = data.ReadFloat();

	float distance;
	char  classname[32];
	GetEntityClassname(door, classname, sizeof(classname));

	if (StrEqual(classname, "func_door_rotating"))
	{
		distance = GetEntPropFloat(door, Prop_Data, "m_flMoveDistance");
	}
	else
	{
		distance = GetEntPropFloat(door, Prop_Data, "m_flDistance");
	}

	float speed = GetEntPropFloat(door, Prop_Data, "m_flSpeed");

	if (speed > 0.0 && distance > 0.0)
	{
		float idealTime = distance / speed;

		if (GetGameTime() - startMovingTime > idealTime + cvStuckTime.FloatValue)
		{
			BecomeGhost(door);
			timerCheckTravelTime[door] = null;
			return Plugin_Stop;
		}
	}

	return Plugin_Continue;
}

// Ghost doors have no collisions and cannot be +used
void BecomeGhost(int door)
{
	if (ghostDoor[door])
	{
		return;
	}

	ghostDoor[door] = true;
	MakeDoorDebris(door);

	// Visual cue
	SetEntityRenderMode(door, RENDER_TRANSTEXTURE);
	SetEntityRenderColor(door, 255, 255, 255, cvTransColor.IntValue);

	// Reset un-ghost timer if any
	delete timerUnghost[door];
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "prop_door_rotating"))
	{
		OnDoorCreated(entity, true);
	}

	else if (StrEqual(classname, "func_door_rotating"))
	{
		OnDoorCreated(entity, false);
	}
}

void OnDoorCreated(int door, bool propbased)
{
	// Clear leftover data
	for (int i = 1; i <= MaxClients; i++)
	{
		nextDoorUseTime[door][i] = 0.0;
	}

	timerUnghost[door]         = null;
	timerCheckTravelTime[door] = null;
	timerUnghostExtended[door] = null;
	ghostDoor[door]            = false;
	numDirChanges[door]        = 0;

	// This prevents doors from bouncing back the moment they
	// come in contact with an object (prop doors might not need this)
	DispatchKeyValue(door, "forceclosed", "1");

	SDKHook(door, SDKHook_ShouldCollide, OnDoorCollide);

	// Only prop doors change direction when +used mid-travel
	// for func_ this would cause false-positives
	if (propbased)
	{
		SDKHook(door, SDKHook_Use, OnDoorUse);
	}
}

// If a door is used while it's moving, we assume it's direction was reversed
// A door that's prevented from resting too many times is considered spammed
// TODO: Decrease numDirChanges count after some time
Action OnDoorUse(int door, int activator, int caller, UseType type, float value)
{
	if (!IsValidEdict(door) || ghostDoor[door])
	{
		return Plugin_Handled;
	}

	float curTime = GetGameTime();
	if (IsPlayer(caller))
	{
		if (curTime < nextDoorUseTime[door][caller])
		{
			return Plugin_Handled;
		}

		// A rate limit is required limit for "OnOpen" output to fire
		// if the player spams +use on a door every frame
		float useRate = cvUseRate.FloatValue;
		if (useRate < 0.1)
		{
			useRate = 0.1;
		}

		nextDoorUseTime[door][caller] = curTime + useRate;
	}

	if (IsDoorMoving(door))
	{
		numDirChanges[door]++;

		if (numDirChanges[door] >= cvFailOpenLimit.IntValue)
		{
			numDirChanges[door] = 0;
			BecomeGhost(door);
		}
	}

	return Plugin_Continue;
}

bool IsDoorMoving(int door)
{
	char classname[32];
	GetEntityClassname(door, classname, sizeof(classname));

	if (StrEqual(classname, "func_door_rotating"))
	{
		int state = GetEntProp(door, Prop_Data, "m_toggle_state");
		return state == TS_GOING_UP || state == TS_GOING_DOWN;
	}
	else
	{
		int state = GetEntProp(door, Prop_Data, "m_eDoorState");
		return state == DOOR_STATE_OPENING || state == DOOR_STATE_CLOSING;
	}
}

// This takes care of doors colliding with props which aren't affected by solid flags
bool OnDoorCollide(int entity, int collisiongroup, int contentsmask, bool originalResult)
{
	return ghostDoor[entity] ? false : originalResult;
}

bool IsDoorTouchingPlayers(int door)
{
	// TODO: Because I can't be bothered to figure out door rotations
	// this is currently done from the players' AABBs, we should change that
	_traceResult = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerAlive(i))
		{
			float mins[3], maxs[3], pos[3];
			GetClientAbsOrigin(i, pos);
			GetClientMins(i, mins);
			GetClientMaxs(i, maxs);

			TR_EnumerateEntitiesHull(pos, pos, mins, maxs, PARTITION_NON_STATIC_EDICTS, PlayerAABBEnumerator, door);

			if (_traceResult)
			{
				return true;
			}
		}
	}

	return false;
}

bool PlayerAABBEnumerator(int entity, int door)
{
	if (entity != door)
	{
		return true;
	}

	TR_ClipCurrentRayToEntity(MASK_ALL, entity);
	_traceResult = TR_DidHit();
	return !_traceResult;
}

void UndoGhost(int door)
{
	ghostDoor[door]    = false;
	timerUnghost[door] = null;
	MakeDoorSolid(door);

	SetEntityRenderMode(door, RENDER_NORMAL);
	SetEntityRenderColor(door);
}

bool IsPlayer(int entity)
{
	return 0 < entity <= MaxClients;
}

void MakeDoorSolid(int door)
{
	RunEntVScript(door, "RemoveSolidFlags(FSOLID_NOT_SOLID)");
}

void MakeDoorDebris(int door)
{
	RunEntVScript(door, "AddSolidFlags(FSOLID_NOT_SOLID)");
}
