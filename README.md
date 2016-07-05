# razberry-altui
Razberry Lua driver

Tested on Raspberry PI 2 with Razberry daughter card running openLuup & ALTUI plugin

- Device detection & creation
- Status refreshes
- Seen as any other devices in ALTUI screens
- Only supports Fibaro Wall Plug for now, could be working with other zwave device supporting cmd class 37 and 49
- exposes the manufacturor ID the product type ID and the product ID in a openLuup device variable "ZW_PID" for future reference 
