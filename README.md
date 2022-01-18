# [NMRiH] Door Grief Protection

Prevents doors from being blocked by:

- Players standing in the way
- Players spamming +use on them
- NPCs closing them
- Weapons and other physics props

When a door is jammed it will briefly appear translucent and disable its collisions, allowing players to walk right thru it.

https://user-images.githubusercontent.com/11559683/149871985-8cf566ad-a1a2-43bd-9a7e-f8c459272c92.mp4


## Installation
0. (Optional) Update to Sourcemod 1.11.6826 or higher. This is recommended as it fixes some collision problems.
1. Grab the latest ZIP from [releases](https://github.com/dysphie/nmrih-door-protect/releases)
2. Extract its contents into `addons/sourcemod`
3. Refresh your loaded plugins (`sm plugins refresh` or `sm plugins load nmrih-door-protect`)

## CVars

CVars are saved and read from `cfg/plugin.doorprotect.cfg`

- `sm_door_use_rate` (Default: `0.3`)
  - Rate (in seconds) at which players are allowed to input +use on doors
 
- `sm_door_max_use_count` (Default: `4`) 
	-	A door will become ghost-like if it's prevented from opening this many times

- `sm_door_max_block_seconds` (Default: `1.5`)
	- A door will become ghost-like if it's blocked by an object for this many seconds
	
- `sm_ghost_door_revert_after_seconds` (Default: `4`)
  - A ghost-like door will attempt to revert back to its default properties after this many seconds. 
    If a player is in the way, it will wait till they step out.

- `sm_ghost_door_opacity` (Default: `120`)
	- Transparency value for ghost-like doors, 255 is fully opaque
