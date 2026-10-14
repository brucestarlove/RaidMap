local ADDON, ns = ...

-- Room framing adapted from RaidWhiteboard's TBC arena coordinates (TheLaw).
-- Art stays in the client. Presets save the ordinary map key and slide view,
-- so packs still open on older RaidMap versions and on other supported clients.
-- Indoor room bounds are pixels on the classic 1002x668 content area.
local function room(key, name, mapKey, x, y, width)
	return { key = key, name = name, mapKey = mapKey, view = { x / 1002, y / 668, 1002 / width } }
end

ns.BossRooms = {
	{ name = "Karazhan", bosses = {
		room("tbc:kz_attumen", "Attumen the Huntsman", "inst:karazhan:1", 455, 545, 280),
		room("tbc:kz_moroes", "Moroes", "inst:karazhan:3", 345, 435, 380),
		room("tbc:kz_maiden", "Maiden of Virtue", "inst:karazhan:4", 838, 333, 220),
		room("tbc:kz_opera", "Opera Event", "inst:karazhan:4", 240, 230, 340),
		room("tbc:kz_curator", "The Curator", "inst:karazhan:9", 450, 190, 300),
		room("tbc:kz_illhoof", "Terestian Illhoof", "inst:karazhan:11", 530, 470, 320),
		room("tbc:kz_aran", "Shade of Aran", "inst:karazhan:10", 720, 165, 200),
		room("tbc:kz_nether", "Netherspite", "inst:karazhan:13", 365, 285, 460),
		room("tbc:kz_chess", "Chess Event", "inst:karazhan:14", 360, 395, 560),
		room("tbc:kz_prince", "Prince Malchezaar", "inst:karazhan:17", 510, 255, 460),
		room("tbc:kz_nightbane", "Nightbane", "inst:karazhan:6", 520, 550, 260),
	} },
	{ name = "Gruul's Lair", bosses = {
		room("tbc:gl_maulgar", "High King Maulgar", "inst:gruulslair:1", 560, 400, 260),
		room("tbc:gl_gruul", "Gruul the Dragonkiller", "inst:gruulslair:1", 210, 195, 300),
	} },
	{ name = "Magtheridon's Lair", bosses = {
		room("tbc:ml_magth", "Magtheridon", "inst:magtheridonslair:1", 690, 500, 460),
	} },
	{ name = "Serpentshrine Cavern", bosses = {
		room("tbc:ssc_hydross", "Hydross the Unstable", "inst:serpentshrine:1", 370, 560, 220),
		room("tbc:ssc_lurker", "The Lurker Below", "inst:serpentshrine:1", 400, 385, 260),
		room("tbc:ssc_leo", "Leotheras the Blind", "inst:serpentshrine:1", 380, 190, 190),
		room("tbc:ssc_flk", "Fathom-Lord Karathress", "inst:serpentshrine:1", 475, 116, 180),
		room("tbc:ssc_moro", "Morogrim Tidewalker", "inst:serpentshrine:1", 590, 185, 200),
		room("tbc:ssc_vashj", "Lady Vashj", "inst:serpentshrine:1", 725, 395, 270),
	} },
	{ name = "Tempest Keep", bosses = {
		room("tbc:tk_alar", "Al'ar", "inst:tempestkeep:1", 505, 385, 260),
		room("tbc:tk_vr", "Void Reaver", "inst:tempestkeep:1", 270, 330, 230),
		room("tbc:tk_solarian", "High Astromancer Solarian", "inst:tempestkeep:1", 735, 330, 250),
		room("tbc:tk_kael", "Kael'thas Sunstrider", "inst:tempestkeep:1", 505, 135, 300),
	} },
	{ name = "Mount Hyjal", bosses = {
		room("tbc:hy_rage", "Rage Winterchill", "inst:hyjalsummit:0", 105, 440, 220),
		room("tbc:hy_anetheron", "Anetheron", "inst:hyjalsummit:0", 105, 440, 220),
		room("tbc:hy_kazrogal", "Kaz'rogal", "inst:hyjalsummit:0", 440, 260, 280),
		room("tbc:hy_azgalor", "Azgalor", "inst:hyjalsummit:0", 420, 260, 280),
		room("tbc:hy_archi", "Archimonde", "inst:hyjalsummit:0", 810, 240, 260),
	} },
	{ name = "Black Temple", bosses = {
		room("tbc:bt_najentus", "High Warlord Naj'entus", "inst:blacktemple:1", 435, 125, 180),
		room("tbc:bt_supremus", "Supremus", "inst:blacktemple:0", 465, 305, 640),
		room("tbc:bt_akama", "Shade of Akama", "inst:blacktemple:2", 405, 560, 260),
		room("tbc:bt_teron", "Teron Gorefiend", "inst:blacktemple:4", 395, 160, 300),
		room("tbc:bt_gurtogg", "Gurtogg Bloodboil", "inst:blacktemple:3", 560, 270, 260),
		room("tbc:bt_ros", "Reliquary of Souls", "inst:blacktemple:3", 640, 570, 200),
		room("tbc:bt_shahraz", "Mother Shahraz", "inst:blacktemple:5", 680, 250, 220),
		room("tbc:bt_council", "The Illidari Council", "inst:blacktemple:6", 470, 320, 320),
		room("tbc:bt_illidan", "Illidan Stormrage", "inst:blacktemple:7", 530, 400, 560),
	} },
	{ name = "Zul'Aman", bosses = {
		room("tbc:za_akilzon", "Akil'zon", "inst:zulaman:0", 345, 145, 220),
		room("tbc:za_nalorakk", "Nalorakk", "inst:zulaman:0", 400, 515, 230),
		room("tbc:za_janalai", "Jan'alai", "inst:zulaman:0", 555, 490, 200),
		room("tbc:za_halazzi", "Halazzi", "inst:zulaman:0", 590, 160, 200),
		room("tbc:za_hexlord", "Hex Lord Malacrass", "inst:zulaman:0", 700, 350, 240),
		room("tbc:za_zuljin", "Zul'jin", "inst:zulaman:0", 905, 350, 200),
	} },
	{ name = "Sunwell Plateau", bosses = {
		room("tbc:sw_kalecgos", "Kalecgos", "inst:sunwellplateau:0", 305, 340, 200),
		room("tbc:sw_brutallus", "Brutallus", "inst:sunwellplateau:0", 650, 560, 300),
		room("tbc:sw_felmyst", "Felmyst", "inst:sunwellplateau:0", 680, 545, 340),
		room("tbc:sw_twins", "The Eredar Twins", "inst:sunwellplateau:0", 640, 215, 200),
		room("tbc:sw_muru", "M'uru", "inst:sunwellplateau:1", 468, 150, 210),
		room("tbc:sw_kj", "Kil'jaeden", "inst:sunwellplateau:1", 460, 410, 300),
	} },
	{ name = "World Bosses", bosses = {
		{ key = "tbc:wb_kazzak", name = "Doom Lord Kazzak", mapKey = "uimap:1944", view = { 0.602, 0.18, 4.545455 } },
		{ key = "tbc:wb_doomwalk", name = "Doomwalker", mapKey = "uimap:1948", view = { 0.69, 0.452, 4.545455 } },
	} },
}

ns.BossRoomsByKey = {}
for _, raid in ipairs(ns.BossRooms) do
	for _, boss in ipairs(raid.bosses) do
		ns.BossRoomsByKey[boss.key] = boss
	end
end
