// Practice Checkpoints: save the ball's position and speed anywhere on a track, cycle through the saved spots and
// jump back to one to practice a section.
//
// Saving and jumping use the host's Race::SaveBall / Race::LoadBall. A load always turns the run into a practice run
// first (Race::StartPractice): the game's timer stops, its checkpoints and finish stop responding and the leaderboard
// and ghosts are hidden, so a practice run can never post a time. The host ends practice at the next run (a restart);
// that restart loads the checkpoint again, unless it's checkpoint 0 (the start) or the full restart key: then the new
// run is a clean one.
//
// On screen, in the game's own HUD style: while practising, this plugin's timer takes the place of the game's (which
// only shows 999:999.999 then), with a practice line and short messages under it.

[Setting name="Save checkpoint key" description="Type a key name, then press Enter: A-Z, 0-9, F1-F12, Space, Shift, Ctrl, Alt, Tab, Enter, Backspace, Delete, arrows (Up, Down, Left, Right), MouseLeft/Right/Middle, and controller buttons: PadA, PadB, PadX, PadY, PadLB, PadRB, PadLT, PadRT, PadL3, PadR3, PadView, PadMenu, PadUp, PadDown, PadLeft, PadRight"]
string SaveKey = "F5";

[Setting name="Previous checkpoint key" description="Type a key name, then press Enter"]
string PrevKey = "F7";

[Setting name="Next checkpoint key" description="Type a key name, then press Enter"]
string NextKey = "F8";

[Setting name="Delete checkpoint key" description="Type a key name, then press Enter"]
string DeleteKey = "F9";

[Setting name="Delete all checkpoints key" description="Type a key name, then press Enter"]
string ClearKey = "F10";

[Setting name="Full restart key" description="The game's own full restart key: restarting with it goes back to the start (checkpoint 0) for a run that counts, instead of to your checkpoint"]
string FullRestartKey = "Backspace";

[Setting name="Checkpoints window key" description="Opens the window to export, import or clear this map's checkpoints"]
string WindowKey = "F4";

[Setting name="Standing still modifier" description="Hold it while going to the previous or next checkpoint, or while restarting (R), to land there without its speed"]
string StillKey = "Shift";

[Setting name="Follow map checkpoints" description="While practising, touching one of the map's checkpoints makes it your practice checkpoint (saved as a map checkpoint if you don't have it yet). In a run that counts, the game's own checkpoints are left alone"]
bool FollowMap = true;

[Setting name="Turn the camera" description="Going to a checkpoint also turns the camera the way it faced when the checkpoint was saved"]
bool TurnCamera = true;

[Setting name="Show markers" description="A glowing ring on each checkpoint (the first 20)"]
bool ShowMarkers = true;

[Setting name="Show run timer" description="While practising, the run time in place of the game's timer: saved with each checkpoint, and set back to it when you go to one"]
bool ShowTimer = true;

[Setting name="Show run indicator" description="A ball at the top left: green when this run can post a time, red during practice"]
bool ShowIndicator = true;

[Setting name="Timer size" description="23 matches the game's own timer" min=12 max=64]
float TimerSize = 23;

[Setting name="Debug log" description="Log every save, load and practice step"]
bool DebugLog = false;

class Checkpoint
{
    string state;                   // Race::SaveBall's text
    array<double> pos = array<double>(3);
    double time = 0;                // the run timer when it was saved
    bool airborne = false;          // saved off the ground (read from the ball's isOnGround just after)
    bool fromMap = false;           // made from one of the map's own checkpoints
    string name;                    // the player's name for it, or ""
    int attempts = 0;               // this session: how many times it was gone to (not saved)
}

// A name fits in the export code (no , | ; which separate it) and in a list row.
const uint NAME_MAX = 24;

string CleanName(const string &in raw)
{
    string s = raw;
    for (uint i = 0; i < s.length(); i++)
        if (s[i] == 44 || s[i] == 124 || s[i] == 59 || s[i] < 32)     // , | ; and control characters
            s[i] = 32;
    s = Trim(s);
    return s.length() > NAME_MAX ? Trim(s.substr(0, NAME_MAX)) : s;
}

array<Checkpoint@> checkpoints;
int current = -1;

// --- console commands and their results -----------------------------------------------------------------------------
//
// The markers and the countdown skip still go through the host's console ("callx" and friends, results read back
// from the log), since the plugin API has nothing for them.

// Each command walks every object in the game, so only a few are sent a frame.
const uint COMMANDS_PER_FRAME = 3;
array<string> queue;
uint scanFrom = 0;

void Send(const string &in command)
{
    queue.insertLast(command);
}

void Pump()
{
    for (uint n = 0; n < COMMANDS_PER_FRAME && queue.length() > 0; n++)
    {
        Console::Run(queue[0]);
        queue.removeAt(0);
    }
}

void ReadLog()
{
    uint count = Log::LineCount();
    for (uint i = scanFrom; i < count; i++)
    {
        string line = Log::Line(i);
        if (markerHat != "" && line.findFirst("cosmetics: built " + markerHat + " on") >= 0)
            OnMarkerHatBuilt();
        int t = line.findFirst("test: ");
        if (t < 0)
            continue;
        string body = line.substr(t + 6);
        if (OnRingLine(body))
            continue;

        // The markers' own lines: their listings (DynamicMeshActors), the hat read, and their end marker.
        bool markerInstance = body.findFirst("instance ") == 0 && body.findFirst(".DynamicMeshActor") >= 0;
        if (markerInstance || body.findFirst("AccessorySlot StaticMesh = ") == 0 || body.findFirst(MARKER_LIST_DONE) == 0 ||
            body.findFirst("no instance of BP_RollingBall_C") == 0)
            OnMarkerLine(body);
        else if (groundPending !is null && body.findFirst("  isOnGround (") == 0)
        {
            // "  isOnGround (BoolProperty) @0x4e3 size 1 = 01"
            groundPending.airborne = body.findLast("= 00") >= 0;
            if (DebugLog)
                Log::Info("checkpoint saved " + (groundPending.airborne ? "in the air" : "on the ground"));
            @groundPending = null;
            Persist();
        }
        else if (body.findFirst("callx IsAnyAnimationPlaying(") == 0 && ReadByte(body) == 1)
            OnCountdownPlaying();
    }
    scanFrom = count;
}

// "... ReturnValue=03": a one-byte result, or -1.
int ReadByte(const string &in body)
{
    int at = body.findFirst("ReturnValue=");
    if (at < 0 || body.findFirst(" ok ") < 0 || int(body.length()) < at + 14)
        return -1;
    return HexDigit(body[at + 12]) * 16 + HexDigit(body[at + 13]);
}

int HexDigit(uint8 c)
{
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 97 && c <= 102) return c - 87;
    if (c >= 65 && c <= 70) return c - 55;
    return 0;
}

// --- main loop ----------------------------------------------------------------------------------------------------

bool wasOnTrack = false;
bool inBall = false;                // on a track, controlling the ball
int seenRestarts = 0;
double runTime = 0;                 // the run timer: counts while the race runs, set to a checkpoint's time on a jump

void Main()
{
    BuildHud();
    BuildWindow();
    seenRestarts = Race::Restarts();
    scanFrom = Log::LineCount();
    OnSettingsChanged();
}

// Turned off or removed: the game goes back to how it was. The host takes the windows away itself. This is the last
// call, so nothing goes through the Send queue: Console::Run commands are run by the host.
void OnDisabled()
{
    // A practice run ends with a full restart, the game's own, as its restart key does (a clean run from the start,
    // with the game's respawn point back on its own checkpoints).
    if (Race::OnTrack() && (practising || Race::IsPractice()))
        Console::Run("callx BP_MyPlayerController_C ManuallyRestartBall");
    if (gameTimerOff)
        HideGameTimer(false);
    ForgetMarkers();                // the marker hat off: the host destroys the markers with it
}

void OnSettingsChanged()
{
    SizeHud();
    CheckKey("Save checkpoint", SaveKey);
    CheckKey("Previous checkpoint", PrevKey);
    CheckKey("Next checkpoint", NextKey);
    CheckKey("Delete checkpoint", DeleteKey);
    CheckKey("Delete all checkpoints", ClearKey);
    CheckKey("Full restart", FullRestartKey);
    CheckKey("Checkpoints window", WindowKey);
    CheckKey("Standing still modifier", StillKey);
}

// A key name nobody could press does nothing, silently: say so.
void CheckKey(const string &in action, const string &in name)
{
    if (KeyCode(name) == 0)
        Warn(action + ": '" + name + "' is not a key");
}

void Update(float dt)
{
    bool onTrack = Race::OnTrack() && !Replay::IsActive();
    // Controlling a ball: not while editing in the track editor (an editor camera then).
    double inputX, inputY;
    bool inputJump;
    bool wasInBall = inBall;
    inBall = onTrack && Race::GetInput(inputX, inputY, inputJump);
    if (DebugLog && inBall != wasInBall)
        Log::Info(inBall ? "controlling the ball" : "not controlling the ball");
    DropStrayMarkerHat();           // before the markers look at the hat worn
    if (wasOnTrack && !onTrack)
        LeftTrack();
    wasOnTrack = onTrack;

    ReadLog();
    if (onTrack && Race::IsActive())
        runTime += dt;

    if (onTrack)
    {
        LoadMapCheckpoints();
        // The map's own checkpoints, always in the list: surveyed once playing starts, and again after the track
        // editor (new strips may have been placed).
        if (inBall && !wasInBall)
            stripsReady = false;
        if (inBall && mapLoaded && !stripsReady && ringState == RingsIdle)
            StartSurvey(true);
        NoteSpawn();
        UpdateWindow();
        HandleKeys();
        if (Pressed(FullRestartKey))
            fullRestartAt = Host::Time();
        WatchRestarts();
        KeepPractice();
        WatchNewBall(wasInBall);
        SampleBall();
        UpdateMarkers();
    }
    Pump();
    RefreshHud(onTrack);
}

// The keys only do something while the player is racing: not in the track editor's edit mode, a menu, the pause menu
// or before the race has started, and not while typing in a text box (the game's own: a plugin's text box already
// keeps its keys). Editor::Typing walks every object, so it's only asked once one of these keys is down.
void HandleKeys()
{
    bool save = Pressed(SaveKey), prev = Pressed(PrevKey), next = Pressed(NextKey);
    bool remove = Pressed(DeleteKey), clear = Pressed(ClearKey);
    if (!save && !prev && !next && !remove && !clear)
        return;
    string why = !Race::IsActive() ? "the race isn't running" : Race::IsPaused() ? "paused" :
                 UI::CursorShown() ? "a menu is open" : Editor::Typing() ? "typing" : "";
    if (why != "")
    {
        if (DebugLog)
            Log::Info("key ignored: " + why);
        return;
    }
    if (save)
        Save();
    if (prev)
        Cycle(-1);
    if (next)
        Cycle(1);
    if (remove)
        DeleteCurrent();
    if (clear)
        ClearAll();
}

void LeftTrack()
{
    gameSpawnAt = "";
    stripsReady = false;
    ringState = RingsIdle;
    insideStrip = -1;
    followLastKnown = false;
    ForgetMarkers();
    practising = false;
    practiceDropped = false;
    queue.resize(0);
    runTime = 0;
    restartedAt = -1;
    loadAfterStart = false;
    @spawn = null;
    CloseWindow();
    // They're kept on disk under the map: loaded again when it's played next.
    checkpoints.resize(0);
    current = -1;
    mapKey = "";
    mapLoaded = false;
}

// --- saving -------------------------------------------------------------------------------------------------------

void Save()
{
    string state = Race::SaveBall();
    if (state == "")
    {
        Warn("no ball to save");
        return;
    }
    Checkpoint@ cp = Checkpoint();
    cp.state = state;
    cp.time = runTime;
    @groundPending = cp;
    Console::Run("props BP_RollingBall_C");        // its isOnGround line: was it saved in the air?
    ReadLine(state, "L", cp.pos);
    checkpoints.insertLast(cp);
    current = int(checkpoints.length()) - 1;
    Persist();
    Say("checkpoint " + (current + 1) + " saved");
    if (DebugLog)
        Log::Info("saved at " + FormatTime(cp.time) + ":\n" + state);
}

// --- going to a checkpoint ----------------------------------------------------------------------------------------

// Checkpoint 0 is the start: where the ball is when a run that counts gets going. It is noted then (once per map), and going to
// it puts the ball there standing still. A restart while on it is an ordinary one: that run counts.
Checkpoint@ spawn;

void NoteSpawn()
{
    if (spawn !is null || practising || Race::IsPractice() || !Race::IsActive() || runTime > 0.1)
        return;
    string state = Race::SaveBall();
    if (state == "")
        return;
    @spawn = Checkpoint();
    spawn.state = state;
    ReadLine(state, "L", spawn.pos);
    if (DebugLog)
        Log::Info("start noted:\n" + state);
}

// Once a checkpoint has been loaded, the run is a practice run until a restart that doesn't load one.
bool practising = false;

Checkpoint@ groundPending;          // a checkpoint just saved, waiting for the ball's isOnGround

// A checkpoint saved in the air: the ball mustn't be able to jump there. It can, when it comes from the ground (on a
// restart the game puts it on the start pad for a frame first), since the game only clears its jump when the ball
// leaves the ground. So it's told the ball is in the air; landing gives the jump back as usual.
void NoJump()
{
    Console::Run("callx BP_RollingBall_C DisableJump");
    Console::Run("callx BP_RollingBall_C SetIsOnGround | b:0 | s:practice");
}

// camera: Race::SaveBall text whose camera lines replace the checkpoint's (with TurnCamera off); "" for the camera
// as it is now.
bool GoTo(int index, const string &in camera = "", bool keepSpeed = true)
{
    if (index >= int(checkpoints.length()))
        return false;
    if (index < 0 && spawn is null)
    {
        Say("the start isn't known yet");
        return false;
    }
    Checkpoint@ cp = index < 0 ? spawn : checkpoints[index];
    string state = cp.state;
    if (!TurnCamera)
    {
        string keep = camera != "" ? camera : Race::SaveBall();
        if (keep != "")
            state = WithCamera(cp.state, keep);
    }
    // LoadBall starts practice before it moves the ball, and refuses (false) when it couldn't.
    if (!Race::LoadBall(state, index >= 0 && keepSpeed))       // the start: standing still
    {
        Warn("couldn't move the ball");
        return false;
    }
    practising = true;
    practiceDropped = false;
    ownMoveAt = Host::Time();
    loadedStill = !keepSpeed;
    runTime = cp.time;
    if (cp.airborne)
        NoJump();
    if (index >= 0)
        SetGameSpawn(cp);
    if (DebugLog)
        Log::Info("loaded checkpoint " + (index + 1) + " (practice " + (Race::IsPractice() ? "on" : "OFF") + ")");
    return true;
}

// ".../PersistentLevel.MP_ActualCheckpoint_Strip_C_2147458976" -> "MP_ActualCheckpoint_Strip_C"
string ClassOfPath(const string &in path)
{
    string name = path.substr(path.findLast(".") + 1);
    int cut = name.findLast("_");
    return cut > 0 ? name.substr(0, cut) : name;
}

// The game's own respawn point (the player controller's RespawnLocation) put on the practice checkpoint, so dying or
// R after a map checkpoint brings the ball back there by itself. There's no call to set it; a map checkpoint strip sets
// it to its arrow (UpdatePlayerSpawn: the arrow's location, 50 up, measured), so one strip's arrow is moved onto the
// checkpoint for the call and put back after. Only in a practice run: a run that counts must respawn where the game
// says. (A run that counts only uses it after touching a map checkpoint, which sets it anew.)
// Set once per checkpoint: again only after something else moved the game's respawn point (touching one of the map's
// checkpoints; the game only uses it after one is touched). Each console call searches every object in the game, and respawns hitched.
string gameSpawnAt;                 // the checkpoint spot the game's respawn point was last put on; "" when unknown

void SetGameSpawn(Checkpoint@ cp)
{
    if (!stripsReady && ringState == RingsIdle)
        StartSurvey(false);             // ready for the next load
    if (!Race::IsPractice() || !stripsReady)
        return;
    if (gameSpawnAt == VecText(cp.pos))
        return;
    gameSpawnAt = VecText(cp.pos);
    int strip = -1;
    for (uint i = 0; i < ringPaths.length() && strip < 0; i++)
        if (ringSpots[i] !is null && ringTurns[i] !is null)
            strip = int(i);
    if (strip < 0)
        return;
    array<double> facing(3);
    double yaw = ReadLine(cp.state, "C", facing) ? facing[1] : 0;
    string arrow = ringPaths[strip] + "+.Arrow";
    array<double> below = {cp.pos[0], cp.pos[1], cp.pos[2] - RESPAWN_ABOVE_ARROW};
    array<double> turned = {0, yaw, 0};
    Console::Run("callx SceneComponent K2_SetWorldLocation " + arrow + " | v:" + VecText(below) + " | b:0");
    Console::Run("callx SceneComponent K2_SetWorldRotation " + arrow + " | v:" + VecText(turned) + " | b:0");
    Console::Run("callx " + ClassOfPath(ringPaths[strip]) + " UpdatePlayerSpawn " + ringPaths[strip]);
    Console::Run("callx SceneComponent K2_SetWorldLocation " + arrow + " | v:" + VecText(ringSpots[strip]) + " | b:0");
    Console::Run("callx SceneComponent K2_SetWorldRotation " + arrow + " | v:" + VecText(ringTurns[strip]) + " | b:0");
}

void Cycle(int step)
{
    int n = int(checkpoints.length());
    if (n == 0)
    {
        Say("no checkpoint yet: press " + SaveKey);
        return;
    }
    // Positions 0 (the start, current -1) to n.
    int at = ((current + 1 + step) % (n + 1) + n + 1) % (n + 1);
    current = at - 1;
    bool still = Held(StillKey);
    if (current >= 0)
        checkpoints[current].attempts++;
    GoTo(current, "", !still);
    if (current < 0)
        Say("checkpoint 0: the start (restart here for a run that counts)");
    else if (still)
        Say("checkpoint " + (current + 1) + ", standing still");
}

void DeleteCurrent()
{
    if (current < 0 || current >= int(checkpoints.length()))
        return;
    string name = checkpoints[current].name;
    checkpoints.removeAt(uint(current));
    Say("checkpoint " + (current + 1) + (name == "" ? "" : " (" + name + ")") + " deleted");
    if (current >= int(checkpoints.length()))
        current = int(checkpoints.length()) - 1;
    Persist();
}

// The player's own checkpoints on this map, saved ones too; the map's own stay (they're always there: added again
// whenever the map is surveyed). The run stays a practice run: only a restart makes the next one count.
void ClearAll()
{
    for (int i = int(checkpoints.length()) - 1; i >= 0; i--)
        if (!checkpoints[i].fromMap)
            checkpoints.removeAt(uint(i));
    current = -1;
    Persist();
    Say("your checkpoints deleted for this map (the map's stay)");
}

// --- per map, on disk ---------------------------------------------------------------------------------------------
//
// Each map's checkpoints are kept in Storage under "map:<track key>" (a track editor map by its name), in the same
// text as the export code, and loaded when the map is played. Written on every change: that's only on a key press.

string mapKey;                      // the map the checkpoints in memory belong to; "" before it's known
bool mapLoaded = false;

// The keys the map's checkpoints may be under, the one to use first: "map:Map_Track05", "custom:<workshop id>:<file>",
// "editor:<map>"; none until known. Every track editor map is played on the same level (Map_LevelEditorMain), so those
// go by their own name. That differs by mode (seen: the playtest reports only the map's id, "0936175387", as its
// track name, the editor its name, "practice mod test"), so both are tried.
array<string>@ MapKeys()
{
    array<string> keys;
    string key = Race::TrackKey();
    if (key.findFirst("Map_LevelEditor") < 0)
    {
        if (key != "")
            keys.insertLast(key);
        return keys;
    }
    array<string> names = {Editor::MapName(), Race::TrackName()};
    for (uint i = 0; i < names.length(); i++)
        if (names[i] != "" && keys.find("editor:" + names[i]) < 0)
            keys.insertLast("editor:" + names[i]);
    return keys;
}

void LoadMapCheckpoints()
{
    if (mapLoaded)
        return;
    array<string>@ keys = MapKeys();
    if (keys.length() == 0)
        return;
    mapKey = keys[0];
    mapLoaded = true;
    // Under the first key, or else another (then moved to the first).
    string saved;
    for (uint i = 0; i < keys.length() && saved == ""; i++)
    {
        saved = Storage::Get("map:" + keys[i], "");
        if (saved != "" && i > 0)
        {
            Storage::Set("map:" + keys[0], saved);
            Storage::Set("map:" + keys[i], "");
        }
    }
    array<Checkpoint@>@ loaded = Decode(saved);
    uint count = loaded is null ? 0 : loaded.length();
    // Anything saved before the map was known (an unsaved editor map) is kept after them.
    bool unsaved = checkpoints.length() > 0;
    for (uint i = 0; i < count; i++)
        checkpoints.insertAt(i, loaded[i]);
    current = -1;
    if (unsaved)
        Persist();
    if (count > 0)
        Say(count + " saved checkpoint" + (count == 1 ? "" : "s") + " for this map");
    if (DebugLog)
        Log::Info("map " + join(keys, " / ") + ": " + count + " checkpoints loaded");
}

void Persist()
{
    if (mapKey != "")
        Storage::Set("map:" + mapKey, checkpoints.length() == 0 ? "" : Encode(checkpoints));
    RefreshWindow();
}

// --- export code --------------------------------------------------------------------------------------------------
//
//   pcp1:<time>,<flags>,<state>[,<name>]|<time>,...
//
// Flags: 1 saved in the air, 2 made from one of the map's checkpoints (older codes only have 0 or 1). The name is only
// there when the checkpoint has one, so a code without names still imports into older versions.
//
// The state is Race::SaveBall's text with its lines joined by ";" and its numbers cut to 3 decimals.

const string CODE_PREFIX = "pcp1:";

string Encode(const array<Checkpoint@>@ list)
{
    array<string> parts;
    for (uint i = 0; i < list.length(); i++)
        parts.insertLast(Short(list[i].time) + "," + formatInt((list[i].airborne ? 1 : 0) + (list[i].fromMap ? 2 : 0)) + "," +
                         CompactState(list[i].state) + (list[i].name == "" ? "" : "," + CleanName(list[i].name)));
    return CODE_PREFIX + join(parts, "|");
}

// The checkpoints in a code, or null when it isn't one.
array<Checkpoint@>@ Decode(const string &in raw)
{
    string code = Trim(raw);
    if (code.findFirst(CODE_PREFIX) != 0)
        return null;
    array<Checkpoint@> list;
    array<string>@ parts = code.substr(CODE_PREFIX.length()).split("|");
    for (uint i = 0; i < parts.length(); i++)
    {
        array<string>@ fields = parts[i].split(",");
        if (fields.length() != 3 && fields.length() != 4)
            return null;
        Checkpoint@ cp = Checkpoint();
        cp.time = parseFloat(fields[0]);
        int flags = int(parseInt(fields[1]));
        cp.airborne = (flags & 1) != 0;
        cp.fromMap = (flags & 2) != 0;
        cp.state = join(fields[2].split(";"), "\n") + "\n";
        if (fields.length() == 4)
            cp.name = CleanName(fields[3]);
        if (!ReadLine(cp.state, "L", cp.pos))
            return null;
        list.insertLast(cp);
    }
    return list;
}

string CompactState(const string &in state)
{
    array<string> lines;
    array<string>@ raw = state.split("\n");
    for (uint i = 0; i < raw.length(); i++)
    {
        if (Trim(raw[i]) == "")
            continue;
        array<string>@ tokens = Trim(raw[i]).split(" ");
        for (uint k = 1; k < tokens.length(); k++)
        {
            if (tokens[k].length() == 0)
                continue;
            uint8 c = tokens[k][0];
            if ((c >= 48 && c <= 57) || c == 45 || c == 46)        // a number (names start with a letter)
                tokens[k] = Short(parseFloat(tokens[k]));
        }
        lines.insertLast(join(tokens, " "));
    }
    return join(lines, ";");
}

// 3 decimals at most, no trailing zeros: 12.5, -3955, 0.001
string Short(double v)
{
    string s = formatFloat(v, "", 0, 3);
    if (s.findFirst(".") >= 0)
    {
        int end = int(s.length());
        while (end > 0 && s[end - 1] == 48)
            end--;
        if (end > 0 && s[end - 1] == 46)
            end--;
        s = s.substr(0, end);
    }
    return s == "-0" ? "0" : s;
}

// The host ends practice by itself when the run changes. That's meant to happen at a restart (handled below), but a
// ball this plugin moved must never be in a run that counts: if practice drops while the run is still ours, it goes
// back on. A restart can be seen a frame after the new run, so the drop waits one frame for it.
bool practiceDropped = false;

void KeepPractice()
{
    if (!practising || Race::IsPractice())
    {
        practiceDropped = false;
        return;
    }
    // A restart to a checkpoint is under way (the ball is on it): no waiting, the run is ours.
    if (!practiceDropped && !LoadPending())
    {
        practiceDropped = true;
        return;
    }
    practiceDropped = false;
    Race::StartPractice();
    if (DebugLog)
        Log::Info("practice dropped without a restart: " + (Race::IsPractice() ? "back on" : "COULD NOT turn it back on"));
}

// A checkpoint respawn: once the ball has been through one of the map's checkpoints, dying (or R) doesn't restart the
// race: the game moves the same ball back to that checkpoint (measured: no new ball, practice stays on, Race::Restarts
// doesn't change). So while practising, the ball's position is noted ten times a second, and a jump further than its
// speed could take it, that this plugin didn't make, is the game putting it back: it goes to the practice checkpoint
// instead, like a restart would. With checkpoint 0 (the start) selected, it becomes a real restart instead, the game's
// own (as its restart key does): the ball back on the start, in a run that counts.
//
// Race::SaveBall asks the ball for its camera parts, too costly every frame (measured: the game lagged), so the ball
// is sampled ten times a second, one read shared with the camera notes (KeepingCamera).
const double RESPAWN_JUMP = 400;    // at least this far between two samples
const double SAMPLE_EVERY = 0.1;
array<double> lastBallPos(3);
bool lastBallKnown = false;
double ownMoveAt = -100;            // when this plugin last moved the ball
bool loadedStill = false;            // the last load was without speed on purpose (the modifier): still is expected
double sampledAt = -1;

// The other kind of checkpoint respawn: in a run that counts, the game gives a new ball there instead of moving this
// one, so control goes away and comes back (as for a restart, but no restart follows: a restart's count comes ~25 ms
// after the ball, measured). With a checkpoint of the player's own selected (or practising), it's the one the ball goes
// to.
const double NEW_BALL_WAIT = 0.3;
double ballBackAt = -1;             // when control of a ball last came back, while waiting to see if a restart follows

void WatchNewBall(bool wasInBall)
{
    if (inBall && !wasInBall)
        ballBackAt = Host::Time();
    if (ballBackAt < 0 || Host::Time() - ballBackAt < NEW_BALL_WAIT)
        return;
    ballBackAt = -1;
    bool own = current >= 0 && current < int(checkpoints.length()) && !checkpoints[current].fromMap;
    if (!inBall || !Race::IsActive() || LoadPending() || current < 0 || !(own || practising) || LegitMapRespawns())
        return;
    RespawnLoad();                  // (the restart counts the attempt)
    if (DebugLog)
        Log::Info("new ball without a restart: restarting to checkpoint " + (current + 1));
}

// After a game respawn, the game holds the ball still for up to a second and turns the camera its own way (measured:
// speed given back was stopped again up to ~1 s later, and reloads during it made the camera jitter). A restart has
// none of that: it's the one this plugin controls (WatchRestarts: the checkpoint loaded, the countdown skipped, its
// speed given after the start). So a respawn becomes a real restart, the game's own (as its restart key does), and the
// restart brings the ball to the practice checkpoint.
void RespawnLoad()
{
    ownMoveAt = Host::Time();
    Console::Run("callx BP_MyPlayerController_C ManuallyRestartBall");
}

void SampleBall()
{
    // Watched: practising, on the start (checkpoint 0), or with a checkpoint of the player's own selected in a run that
    // counts (they saved it, then died: the game would put the ball on the last map checkpoint instead). A map
    // checkpoint selected in a run that counts is left to the game: it respawns the ball there itself, legitimately.
    bool own = current >= 0 && current < int(checkpoints.length()) && !checkpoints[current].fromMap;
    bool watching = inBall && (practising || current < 0 || own) && !LoadPending() && Race::IsActive() &&
                    !LegitMapRespawns();
    bool camera = KeepingCamera();
    bool following = Following();
    if (!watching)
        lastBallKnown = false;
    if (!following)
        followLastKnown = false;
    if ((!watching && !camera && !following) || Host::Time() - sampledAt < SAMPLE_EVERY)
        return;
    double elapsed = Host::Time() - sampledAt;
    sampledAt = Host::Time();
    string state = Race::SaveBall();
    if (state == "")
    {
        lastBallKnown = false;
        return;
    }
    if (camera)
        NoteCamera(state);
    if (following)
    {
        array<double> at(3), speed(3);
        if (ReadLine(state, "L", at))
        {
            ReadLine(state, "V", speed);
            FollowMapCheckpoints(at, speed, elapsed);
        }
    }
    if (watching)
        WatchRespawn(state, elapsed);
}

void WatchRespawn(const string &in state, double elapsed)
{
    array<double> at(3), speed(3);
    if (!ReadLine(state, "L", at))
    {
        lastBallKnown = false;
        return;
    }
    ReadLine(state, "V", speed);
    // The game respawns the ball on the practice checkpoint itself (SetGameSpawn), standing still: a checkpoint saved
    // with speed, with the ball on its very spot and not moving, is that, even when it didn't jump far to get there.
    if (current >= 0 && !loadedStill && Host::Time() - ownMoveAt > 0.6 && Length(speed) < 5 &&
        Distance2(at, checkpoints[current].pos) < 30 * 30 && HasSpeed(checkpoints[current]))
    {
        lastBallKnown = false;
        RespawnLoad();                  // (the restart counts the attempt)
        if (DebugLog)
            Log::Info("respawned on the checkpoint standing still: restarting to it");
        return;
    }
    if (lastBallKnown && Host::Time() - ownMoveAt > 0.6)      // (the game settles a respawn in steps)
    {
        double reach = RESPAWN_JUMP;
        double rolled = Length(speed) * elapsed * 2.5;
        if (rolled > reach)
            reach = rolled;
        if (Distance2(at, lastBallPos) > reach * reach)
        {
            lastBallKnown = false;
            ownMoveAt = Host::Time();
            if (current < 0)
            {
                Console::Run("callx BP_MyPlayerController_C ManuallyRestartBall");
                if (DebugLog)
                    Log::Info("checkpoint respawn seen: restarting from the start (checkpoint 0)");
                return;
            }
            RespawnLoad();                  // (the restart counts the attempt)
            if (DebugLog)
                Log::Info("checkpoint respawn seen: restarting to checkpoint " + (current + 1));
            return;
        }
    }
    lastBallPos = at;
    lastBallKnown = true;
}


// Saved moving (its V line faster than a crawl).
bool HasSpeed(Checkpoint@ cp)
{
    array<double> v(3);
    return ReadLine(cp.state, "V", v) && Length(v) > 50;
}

double Length(const array<double>@ v)
{
    // No sqrt needed to compare, but the speed is wanted in units: a few Newton steps.
    double s = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if (s <= 0)
        return 0;
    double r = s > 1 ? s / 2 : 1;
    for (int i = 0; i < 20; i++)
        r = (r + s / r) / 2;
    return r;
}

// Following the map's checkpoints: while practising, touching one of them makes it the practice checkpoint (one made
// from it, or a new one there). The map's checkpoint strips are surveyed once per map (see "the map's own checkpoints": each one's box,
// arrow and direction), and the ball's path between two samples (SampleBall, ten a second) is checked against their
// boxes: entering one is touching it. (Reading the game's own respawn point instead needs the host's "membytes", which
// scans the whole process's memory map on every read: the game lagged.)
int insideStrip = -1;               // the strip the ball is in, or -1
array<double> followLast(3);
bool followLastKnown = false;

bool Following()
{
    return FollowMap && inBall && Race::IsActive();
}

void FollowMapCheckpoints(const array<double>@ at, const array<double>@ speed, double elapsed)
{
    if (!stripsReady)
    {
        if (ringState == RingsIdle)
            StartSurvey(false);
        return;
    }
    array<double> from = at;
    if (followLastKnown)
        from = followLast;
    // A teleport (a load of this plugin's, or the game's respawn) isn't a path the ball took: whatever it crosses
    // wasn't touched. Same test as for respawns: further than its speed could take it.
    double reach = RESPAWN_JUMP;
    double rolled = Length(speed) * elapsed * 2.5;
    if (rolled > reach)
        reach = rolled;
    if (followLastKnown && (Host::Time() - ownMoveAt < 0.6 || Distance2(at, followLast) > reach * reach))
    {
        followLast = at;
        insideStrip = -1;
        return;
    }
    int inside = -1;
    for (uint i = 0; i < ringPaths.length() && inside < 0; i++)
    {
        if (ringSpots[i] is null)
            continue;
        if (TouchesTrigger(i, from, at))
            inside = int(i);
    }
    followLast = at;
    followLastKnown = true;
    if (inside == insideStrip)
        return;
    insideStrip = inside;
    if (inside < 0)
        return;
    gameSpawnAt = "";                   // the game has put its respawn point on this one
    if (DebugLog)
        Log::Info("touched map checkpoint strip " + inside + ": ball from " + VecText(from) + " to " + VecText(at) +
                  " in " + formatFloat(elapsed, "", 0, 2) + " s");
    // In a run that counts, touching one doesn't select it: the run stays the game's own (see LegitMapRespawns).
    if (Legit())
    {
        legitTouchRestarts = Race::Restarts();
        return;
    }
    array<double>@ arrow = ringSpots[inside];
    array<double> spot = {arrow[0], arrow[1], arrow[2] + RESPAWN_ABOVE_ARROW};
    OnMapCheckpointTouched(spot, ringTurns[inside] is null ? 0 : ringTurns[inside][1]);
}

// A map checkpoint touched in a run that counts: the game's respawns go to it, and are left to the game (no restart,
// no practice load) until the next restart. Race::Restarts doesn't change on a respawn (measured).
int legitTouchRestarts = -1;

bool LegitMapRespawns()
{
    return Legit() && legitTouchRestarts == Race::Restarts();
}

const double BALL_RADIUS = 50;      // the ball touches the trigger when its sphere does (radius ~53, measured)

// Whether the ball, going from a to b, touched strip i's trigger: the path taken into the trigger's own frame, against
// its box grown by the ball's radius. Without the trigger's measurements (a checkpoint of another kind), the whole
// strip's box instead.
bool TouchesTrigger(uint i, const array<double>@ a, const array<double>@ b)
{
    if (auraCenters[i] is null || auraTurns[i] is null || auraLows[i] is null || auraHighs[i] is null ||
        auraScales[i] is null)
        return ringMins[i] !is null && SegmentHitsBox(a, b, ringMins[i], ringMaxs[i]);
    array<double> low(3), high(3);
    for (int k = 0; k < 3; k++)
    {
        double s = auraScales[i][k] < 0 ? -auraScales[i][k] : auraScales[i][k];
        low[k] = auraLows[i][k] * s - BALL_RADIUS;
        high[k] = auraHighs[i][k] * s + BALL_RADIUS;
    }
    return SegmentHitsBox(ToLocal(a, auraCenters[i], auraTurns[i]), ToLocal(b, auraCenters[i], auraTurns[i]), low, high);
}

// A world point in the frame of something at `center` turned by `turn` (pitch, yaw, roll, degrees, as Unreal's
// rotators: the rows are its forward, right and up axes).
array<double>@ ToLocal(const array<double>@ p, const array<double>@ center, const array<double>@ turn)
{
    double toRad = PI / 180;
    double sp = Sin(turn[0] * toRad), cp = Cos(turn[0] * toRad);
    double sy = Sin(turn[1] * toRad), cy = Cos(turn[1] * toRad);
    double sr = Sin(turn[2] * toRad), cr = Cos(turn[2] * toRad);
    double dx = p[0] - center[0], dy = p[1] - center[1], dz = p[2] - center[2];
    array<double> local(3);
    local[0] = dx * (cp * cy) + dy * (cp * sy) + dz * sp;
    local[1] = dx * (sr * sp * cy - cr * sy) + dy * (sr * sp * sy + cr * cy) + dz * (-sr * cp);
    local[2] = dx * -(cr * sp * cy + sr * sy) + dy * (cy * sr - cr * sp * sy) + dz * (cr * cp);
    return local;
}

const double PI = 3.14159265358979;

// The script has no sin or cos: a Taylor series on the angle brought into [-pi, pi].
double Sin(double x)
{
    while (x > PI)
        x -= 2 * PI;
    while (x < -PI)
        x += 2 * PI;
    double term = x, sum = x;
    for (int n = 1; n < 12; n++)
    {
        term *= -x * x / ((2 * n) * (2 * n + 1));
        sum += term;
    }
    return sum;
}

double Cos(double x)
{
    return Sin(x + PI / 2);
}

bool EndsWith(const string &in s, const string &in end)
{
    return s.length() >= end.length() && s.substr(s.length() - end.length()) == end;
}

// Whether the segment from a to b goes through the box (slabs).
bool SegmentHitsBox(const array<double>@ a, const array<double>@ b, const array<double>@ low, const array<double>@ high)
{
    double enter = 0, leave = 1;
    for (int k = 0; k < 3; k++)
    {
        double d = b[k] - a[k];
        if (d == 0)
        {
            if (a[k] < low[k] || a[k] > high[k])
                return false;
            continue;
        }
        double t1 = (low[k] - a[k]) / d, t2 = (high[k] - a[k]) / d;
        if (t1 > t2)
        {
            double t = t1;
            t1 = t2;
            t2 = t;
        }
        if (t1 > enter)
            enter = t1;
        if (t2 < leave)
            leave = t2;
        if (enter > leave)
            return false;
    }
    return true;
}

void OnMapCheckpointTouched(const array<double>@ spot, double yaw)
{
    int index = -1;
    for (uint k = 0; k < checkpoints.length() && index < 0; k++)
        if (checkpoints[k].fromMap && Distance2(checkpoints[k].pos, spot) < 100 * 100)
            index = int(k);
    if (index < 0)
    {
        Checkpoint@ cp = Checkpoint();
        cp.state = "L " + Short(spot[0]) + " " + Short(spot[1]) + " " + Short(spot[2]) + "\nR 0 " + Short(yaw) +
                   " 0\nV 0 0 0\nA 0 0 0\nC 350 " + Short(yaw) + " 0\n";
        ReadLine(cp.state, "L", cp.pos);
        cp.fromMap = true;
        checkpoints.insertLast(cp);
        index = int(checkpoints.length()) - 1;
        current = index;
        Persist();
        Say("map checkpoint: saved as checkpoint " + (index + 1));
        return;
    }
    if (index != current)
        Say("map checkpoint: checkpoint " + (index + 1));
    current = index;
    RefreshWindow();
}

// A restart puts the ball back at the start. With a checkpoint it's followed by a load (still practice); without
// one (cp 0, the start) the new run is a clean one.
//
// The checkpoint is loaded in the restart's frame, so the ball appears there, and again once the race has started:
// the race start stops the ball, and begins a new run, which ends the host's practice. That drop is caught in the same
// frame (KeepPractice, while the restart's load is pending): the host ends practice in its frame step just before the
// plugins run, with no physics in between, so the finish never gets a physics step to see the ball.
//
// The race itself is started by the countdown widget's animation (WBP_Countdown): when it ends, AnimFinished tells the controller the countdown is complete. Hiding the widget stalls that
// animation (and the race never starts), and calling the controller's CountdownCompleted, DirectStart or EnableRace
// doesn't start it. So once the animation is seen playing, it is stopped and AnimFinished is called on the live
// widget (under /Engine/Transient; the other matches are templates). Without a countdown seen, the load goes out
// anyway once the race runs.
const double RESTART_GIVE_UP = 3.0;
double restartedAt = -1;
bool countdownSkipped = false;
string restartCamera;               // the camera just before the restart (TurnCamera off)
bool restartStill = false;          // the standing still modifier was held at the restart: no speed
double fullRestartAt = -100;        // when the full restart key last went down
const double FULL_RESTART_WINDOW = 0.5;

void WatchRestarts()
{
    int now = Race::Restarts();
    // Not controlling the ball (gone to the track editor's edit mode, say): a restart under way is dropped, and a new
    // one only noted. Skipping the countdown then would start the race, and put the player back in the playtest.
    if (!inBall)
    {
        seenRestarts = now;
        restartedAt = -1;
        loadAfterStart = false;
        return;
    }
    if (now != seenRestarts)
    {
        seenRestarts = now;
        runTime = 0;
        loadAfterStart = false;
        lastBallKnown = false;          // the restart moves the ball: not a respawn
        ballBackAt = -1;                // and the ball it gives is a restart's
        insideStrip = -1;
        followLastKnown = false;
        // The full restart key goes back to the start: checkpoint 0, a clean run.
        if (Host::Time() - fullRestartAt < FULL_RESTART_WINDOW)
        {
            fullRestartAt = -100;
            current = -1;
        }
        if (current >= 0)
        {
            restartCamera = CameraBefore(Host::Time());
            restartStill = Held(StillKey);
            restartedAt = Host::Time();
            countdownSkipped = false;
            checkpoints[current].attempts++;
            GoTo(current, restartCamera, !restartStill);   // on the checkpoint from the first frame; again after the start
        }
        else if (practising)
        {
            practising = false;
            practiceDropped = false;
            Say("clean run: this one counts");
        }
    }
    LoadAfterStart();
    if (restartedAt < 0)
        return;
    if (Host::Time() - restartedAt > RESTART_GIVE_UP)
    {
        restartedAt = -1;
        WaitForStart();
        return;
    }
    if (!countdownSkipped)
        Console::Run("callx UserWidget IsAnyAnimationPlaying Transient+WBP_Countdown");
}

// The countdown's animation was seen playing (from ReadLog): end it now and start the race.
void OnCountdownPlaying()
{
    if (restartedAt < 0 || countdownSkipped || !inBall)
        return;
    countdownSkipped = true;
    restartedAt = -1;
    Console::Run("callx UserWidget StopAllAnimations Transient+WBP_Countdown");
    Console::Run("callx WBP_Countdown_C AnimFinished Transient | o:WBP_Countdown_C,Transient");
    Console::Run("callx UserWidget SetVisibility Transient+WBP_Countdown | u8:1");
    WaitForStart();
}

void WaitForStart()
{
    loadAfterStart = true;
    startSeenFrames = 0;
    startWaitSince = Host::Time();
}

// A restart whose checkpoint load hasn't gone out yet: the run won't count, whatever the game says for now.
bool LoadPending()
{
    return restartedAt >= 0 || loadAfterStart;
}

// Whether this run can post a time.
bool Legit()
{
    return !Race::IsPractice() && !LoadPending();
}

// The console runs those commands on the next frame, and the race start that follows stops the ball (and begins the
// new run). So the load waits for the first frame the race runs (the start has put the ball on the pad by then, and that
// frame is already drawn: it can't be avoided from here).
bool loadAfterStart = false;
int startSeenFrames = 0;
double startWaitSince = 0;

void LoadAfterStart()
{
    if (!loadAfterStart)
        return;
    if (Race::IsActive())
        startSeenFrames++;
    if (startSeenFrames < 1 && Host::Time() - startWaitSince < 2.0)
        return;
    if (!Race::IsActive())              // the race never started (the countdown wasn't skipped after all): leave it be
    {
        loadAfterStart = false;
        return;
    }
    loadAfterStart = false;
    GoTo(current, restartCamera, !restartStill);
}

// --- keeping the camera -------------------------------------------------------------------------------------------
//
// With TurnCamera off, a load keeps the camera as it is: the checkpoint's camera lines are swapped for the current
// ones. A restart is harder: the game turns the camera to the start's direction in the restart's own frame. So while
// practising, the camera is noted ten times a second (with SampleBall's read), and the restart's load uses the last note taken before it. A
// note from the restart's own frame may already be the reset one, so notes that recent are skipped.

double cameraNotedAt = -1;
string cameraNote;
string cameraPrevNote;
double cameraPrevNoteAt = -1;

bool KeepingCamera()
{
    return !TurnCamera && checkpoints.length() > 0;
}

void NoteCamera(const string &in state)
{
    cameraPrevNote = cameraNote;
    cameraPrevNoteAt = cameraNotedAt;
    cameraNote = state;
    cameraNotedAt = Host::Time();
}

// The camera as noted just before `time`, or "" when there's no recent note.
string CameraBefore(double time)
{
    if (!KeepingCamera())
        return "";
    string note = cameraNote;
    double at = cameraNotedAt;
    if (time - at < 0.05)
    {
        note = cameraPrevNote;
        at = cameraPrevNoteAt;
    }
    return at < 0 || time - at > 1.0 ? "" : note;
}

// A SaveBall state's lines: C (control rotation), S (spring arms) and K (cameras) are the camera.
bool IsCameraLine(const string &in line)
{
    return line.findFirst("C ") == 0 || line.findFirst("S ") == 0 || line.findFirst("K ") == 0;
}

// The ball from `ball`, the camera from `camera`.
string WithCamera(const string &in ball, const string &in camera)
{
    string result;
    array<string>@ lines = ball.split("\n");
    for (uint i = 0; i < lines.length(); i++)
        if (lines[i] != "" && !IsCameraLine(lines[i]))
            result += lines[i] + "\n";
    @lines = camera.split("\n");
    for (uint i = 0; i < lines.length(); i++)
        if (IsCameraLine(lines[i]))
            result += lines[i] + "\n";
    return result;
}

// "L 1.5 -2 30.25": the three numbers after a line's tag.
bool ReadLine(const string &in state, const string &in tag, array<double>@ result)
{
    array<string>@ lines = state.split("\n");
    for (uint i = 0; i < lines.length(); i++)
    {
        if (lines[i].findFirst(tag + " ") != 0)
            continue;
        array<string>@ parts = lines[i].split(" ");
        if (parts.length() < 4)
            return false;
        for (uint k = 0; k < 3; k++)
            result[k] = parseFloat(parts[k + 1]);
        return true;
    }
    return false;
}

// --- markers ------------------------------------------------------------------------------------------------------
//
// Plugins can't put anything in the world, but the host builds a custom hat's model as one actor per group
// (DynamicMeshActor, collision off), attached to the hat slot, and afterwards only turns the groups that spin. So the
// markers are a hat: the player's own hat mesh at its size, plus markers.txt's 20 marker groups. Once it is built,
// the marker actors are found (the DynamicMeshActors that weren't there before), detached, hidden, and each shown
// one is moved onto a checkpoint. Taking the hat off (leaving the track) destroys them with the model.

const uint MARKER_COUNT = 20;
const string MARKER_MODEL = "3";      // raise with every change to markers.txt: the host keeps a hat id's first model
enum MarkerState { MarkersOff, MarkersListing, MarkersBuilding, MarkersFinding, MarkersReady, MarkersFailed }
MarkerState markerState = MarkersOff;
string hatMesh = "";
string markerHat = "";              // the hat id this plugin wears for the markers
double markerStepAt = 0;
array<string> beforeActors;         // DynamicMeshActors before the hat was built
array<string> markerActors;
array<string> markerShownAt;        // what each marker shows: a position's text, or "" when hidden

const string MARKER_LIST_DONE = "callx K2_GetActorRotation(";     // the end of a DynamicMeshActor listing

void UpdateMarkers()
{
    bool wanted = ShowMarkers && checkpoints.length() > 0;
    if (markerState == MarkersOff && wanted && Host::Time() - hatOffAt > 1.0)
        StartMarkers();
    else if ((markerState == MarkersListing || markerState == MarkersBuilding || markerState == MarkersFinding) &&
             Host::Time() - markerStepAt > 5.0)
        MarkerFail("the marker hat wasn't built");
    else if (markerState == MarkersReady)
        PlaceMarkers();
}

// Read the hat being worn, then list the DynamicMeshActors there are before the marker hat is built.
void StartMarkers()
{
    if (Cosmetics::Equipped(Cosmetics::Hat) != "")
    {
        MarkerFail("they need one of the game's hats");
        return;
    }
    markerState = MarkersListing;
    markerStepAt = Host::Time();
    hatMesh = "?";
    beforeActors.resize(0);
    Send("objprop StaticMeshComponent PersistentLevel.BP_RollingBall_C+AccessorySlot StaticMesh");
    Send("instances DynamicMeshActor PersistentLevel");
    Send("callx BP_RollingBall_C K2_GetActorRotation");
}

void OnMarkerLine(const string &in body)
{
    if (body.findFirst("AccessorySlot StaticMesh = ") >= 0 && markerState == MarkersListing)
    {
        // "AccessorySlot StaticMesh = StaticMesh /Game/...PirateHat.PirateHat", or "= null" without a hat
        int at = body.findFirst(" /");
        hatMesh = at >= 0 ? body.substr(at + 1) : "";
        // A stray marker hat was just taken off, and the game doesn't put its own hat back until the next ball: the
        // player's hat is the one that stray was made with (its id ends in the mesh's name, the path was stored).
        if (hatMesh == "" && strayHat != "")
        {
            string saved = Storage::Get("hatMesh", "");
            if (saved != "" && strayHat.findLast("-" + saved.substr(saved.findLast(".") + 1)) >= 0)
                hatMesh = saved;
        }
    }
    else if (body.findFirst("instance ") == 0)
    {
        string path = body.substr(9);
        if (markerState == MarkersListing)
            beforeActors.insertLast(path);
        else if (markerState == MarkersFinding && beforeActors.find(path) < 0)
            markerActors.insertLast(path);
    }
    else if (body.findFirst(MARKER_LIST_DONE) == 0 || body.findFirst("no instance of BP_RollingBall_C") == 0)
    {
        if (markerState == MarkersListing)
            WearMarkerHat();
        else if (markerState == MarkersFinding)
            OnMarkersFound();
    }
}

void WearMarkerHat()
{
    if (hatMesh == "?")
    {
        MarkerFail("couldn't read the hat");
        return;
    }
    // One hat per hat mesh, so a player who changes hats gets theirs back in the next marker hat.
    string meshName = hatMesh == "" ? "none" : hatMesh.substr(hatMesh.findLast(".") + 1);
    markerHat = "practice-checkpoints.markers" + MARKER_MODEL + "-" + meshName;
    if (hatMesh != "")
        Storage::Set("hatMesh", hatMesh);
    if (!Cosmetics::AddHat(markerHat, "practice markers", hatMesh, 1.0, "", Plugins::Folder() + "markers.txt"))
    {
        MarkerFail("couldn't make the marker hat");
        return;
    }
    markerState = MarkersBuilding;
    markerStepAt = Host::Time();
    Cosmetics::Equip(Cosmetics::Hat, markerHat);
}

// The host logs "cosmetics: built <id> on <slot>": list again, and the new DynamicMeshActors are the markers.
void OnMarkerHatBuilt()
{
    if (markerState != MarkersBuilding)
        return;
    markerState = MarkersFinding;
    markerStepAt = Host::Time();
    markerActors.resize(0);
    Send("instances DynamicMeshActor PersistentLevel");
    Send("callx BP_RollingBall_C K2_GetActorRotation");
}

void OnMarkersFound()
{
    if (markerActors.length() < MARKER_COUNT)
    {
        MarkerFail("found " + markerActors.length() + " of " + MARKER_COUNT);
        return;
    }
    markerActors.resize(MARKER_COUNT);
    markerShownAt.resize(0);
    for (uint i = 0; i < markerActors.length(); i++)
    {
        // K2_DetachFromActor(LocationRule, RotationRule, ScaleRule): 1 = keep world
        Send("callx DynamicMeshActor K2_DetachFromActor " + markerActors[i] + " | u8:1 | u8:1 | u8:1");
        // Built on the hat slot, they took its scale (0.95 with the pirate hat): back to 1, so the ring's drop below
        // the actor is MARKER_DROP whatever the hat.
        Send("callx DynamicMeshActor SetActorScale3D " + markerActors[i] + " | v:1,1,1");
        Send("callx DynamicMeshActor SetActorHiddenInGame " + markerActors[i] + " | b:1");
        markerShownAt.insertLast("");
    }
    markerState = MarkersReady;
    if (DebugLog)
        Log::Info("markers: " + markerActors.length() + " ready");
}

// markers.txt builds each ring this far below its actor, so the actor goes as far above the checkpoint.
const double MARKER_DROP = 50000;

string MarkerSpot(const array<double>@ pos)
{
    array<double> lifted = {pos[0], pos[1], pos[2] + MARKER_DROP};
    return VecText(lifted);
}

// Only what changed: a marker moves when its checkpoint does, and hides when there's none for it.
void PlaceMarkers()
{
    for (uint i = 0; i < markerActors.length(); i++)
    {
        string want = ShowMarkers && inBall && i < checkpoints.length() ? MarkerSpot(checkpoints[i].pos) : "";
        if (want == markerShownAt[i])
            continue;
        if (want != "")
        {
            Send("callx DynamicMeshActor K2_SetActorLocation " + markerActors[i] + " | v:" + want + " | b:0");
            if (markerShownAt[i] == "")
                Send("callx DynamicMeshActor SetActorHiddenInGame " + markerActors[i] + " | b:0");
        }
        else
            Send("callx DynamicMeshActor SetActorHiddenInGame " + markerActors[i] + " | b:1");
        markerShownAt[i] = want;
    }
}

void MarkerFail(const string &in why)
{
    markerState = MarkersFailed;
    TakeOffMarkerHat();
    Warn("no markers: " + why);
}

// Back to the game's own hat; the host destroys the model, markers and all.
void TakeOffMarkerHat()
{
    if (markerHat != "" && Cosmetics::Equipped(Cosmetics::Hat) == markerHat)
        HatOff();
}

// The game keeps the equipped hat, so a marker hat can outlive its markers: still on after the plugin stopped
// (seen: it came back on the next game start) or on the menu ball. Worn while no markers are being made, it goes.
void DropStrayMarkerHat()
{
    bool ours = markerState == MarkersBuilding || markerState == MarkersFinding || markerState == MarkersReady;
    string worn = Cosmetics::Equipped(Cosmetics::Hat);
    if (!ours && worn.findFirst("practice-checkpoints.markers") == 0)
    {
        strayHat = worn;
        HatOff();
    }
}

// The game puts its own hat back a moment after: the next marker hat waits for it, or it would be made without it.
double hatOffAt = -100;
string strayHat;                    // the last stray marker hat taken off on this map

void HatOff()
{
    Cosmetics::Equip(Cosmetics::Hat, "");
    hatOffAt = Host::Time();
}

void ForgetMarkers()
{
    TakeOffMarkerHat();
    markerState = MarkersOff;
    markerActors.resize(0);
    markerShownAt.resize(0);
    beforeActors.resize(0);
}

string VecText(const array<double>@ v)
{
    return formatFloat(v[0], "", 0, 3) + "," + formatFloat(v[1], "", 0, 3) + "," + formatFloat(v[2], "", 0, 3);
}

// --- on screen ----------------------------------------------------------------------------------------------------
//
// The game's HUD is white text straight on the picture: no panels. So is this, centred at the top where the game's
// own timer is:
//
//                05:39.287           the practice timer, in the game timer's place (which is turned off meanwhile)
//            practice · cp 2 / 5     red while practising (like the indicator); "cp 2 / 5" in white once there are some
//            checkpoint 3 saved      a message for a moment (red for a problem)
//
// Lowercase, like the game's own words ("play", "next track", "overall").
//
// The timer row keeps its height when there's nothing in it, so the rows under it never slide up onto the game's
// timer.

const string GAME_TIMER = "PlayerUI/TimeGroup";
const float HUD_TOP = 26;           // the timer row's top, lined up with the game's timer
const float HUD_WIDTH = 520;        // every row is this wide, its text centred, so the rows share one centre line
const double MESSAGE_SECONDS = 2.5;

// Colours (red, green, blue), linear like every widget colour: the hex in the comment is what shows on screen.
const float BAD_R = 1.0f, BAD_G = 0.1714f, BAD_B = 0.147f;                 // #ff736b practice, problems
const float LIVE_R = 0.5647f, LIVE_G = 0.9047f, LIVE_B = 0.0319f;          // #c6f432 the current checkpoint in the list

UI::Window@ hud;
UI::Text@ timerText;
UI::Text@ statusText;
UI::Text@ messageText;
double messageAt = -100;
bool gameTimerOff = false;

void BuildHud()
{
    @hud = UI::CreateWindow();
    hud.SetAnchor(0.5f, 0);
    hud.SetPivot(0.5f, 0);
    hud.SetOffset(0, HUD_TOP);
    hud.SetBackground(0, 0, 0, 0);
    @timerText = Centred(hud.AddText(" ", 23));
    hud.NewRow();
    @statusText = Centred(hud.AddText("", 13));
    hud.NewRow();
    @messageText = Centred(hud.AddText("", 15));
    hud.movable = true;

    // Top left, under the game's header and splits.
    @indicator = UI::CreateWindow();
    indicator.SetAnchor(0, 0);
    indicator.SetPivot(0, 0);
    indicator.SetOffset(16, 64);
    indicator.SetBackground(0, 0, 0, 0);
    @indicatorBall = indicator.AddImage(Plugins::Folder() + "legit.png", INDICATOR_SIZE, INDICATOR_SIZE);
    indicator.movable = true;
}

// The run indicator: a green ball while this run can post a time, red while it's a practice run (or about to be one).
const float INDICATOR_SIZE = 26;
UI::Window@ indicator;
UI::Image@ indicatorBall;
bool shownLegit = true;

void RefreshIndicator(bool shown)
{
    indicator.visible = shown && ShowIndicator;
    bool legit = Legit();
    if (legit != shownLegit)
    {
        shownLegit = legit;
        indicatorBall.path = Plugins::Folder() + (legit ? "legit.png" : "practice.png");
    }
}

UI::Text@ Centred(UI::Text@ t)
{
    t.SetWidth(HUD_WIDTH);
    t.SetAlign(1);
    return t;
}

void SizeHud()
{
    timerText.size = TimerSize;
    statusText.size = TimerSize * 0.62f < 12 ? 12 : TimerSize * 0.62f;
    messageText.size = TimerSize * 0.65f < 12 ? 12 : TimerSize * 0.65f;
}

void RefreshHud(bool onTrack)
{
    hud.visible = inBall;           // not over the track editor while editing
    RefreshIndicator(hud.visible);
    bool practice = onTrack && practising && (Race::IsPractice() || LoadPending());
    bool timer = practice && ShowTimer;

    // The game's timer shows 999:999.999 while practising: ours goes in its place.
    if (timer != gameTimerOff || (timer && editorTimer && Host::Time() - gameTimerAt > 3.0))
        HideGameTimer(timer);
    timerText.text = timer ? FormatTime(runTime) : " ";

    string count = checkpoints.length() == 0 ? "" : "cp " + (current + 1) + " / " + checkpoints.length();
    if (current >= 0 && current < int(checkpoints.length()) && checkpoints[current].name != "")
        count += "  ·  " + checkpoints[current].name;
    if (current >= 0 && current < int(checkpoints.length()) && checkpoints[current].attempts > 0)
        count += "  ·  attempt " + checkpoints[current].attempts;
    if (practice)
    {
        statusText.text = count == "" ? "practice" : "practice  ·  " + count;
        statusText.SetColor(BAD_R, BAD_G, BAD_B, 1);
    }
    else if (Legit())
        statusText.text = "";       // a run that counts looks like the game's own: no checkpoint counter
    else
    {
        statusText.text = count;
        statusText.SetColor(1, 1, 1, 0.8f);
    }
    statusText.visible = statusText.text != "";
    messageText.visible = Host::Time() - messageAt < MESSAGE_SECONDS;
}

// On a track, Hud keeps the game's timer off. The track editor's playtest has its own copy of the HUD (in
// W_MapEditor) that Hud doesn't reach, so there the timer is faded out through the console instead, again every few
// seconds in case the game fades it back in.
double gameTimerAt = -1;
bool editorTimer = false;

void HideGameTimer(bool off)
{
    gameTimerOff = off;
    gameTimerAt = Host::Time();
    if (off)
    {
        editorTimer = Hud::Elements().find(GAME_TIMER) < 0;
        if (!editorTimer)
            Hud::SetLayout(GAME_TIMER, 0, 0, 1, Hud::Off);
    }
    else
        Hud::ClearLayout(GAME_TIMER);
    if (editorTimer)
        Console::Run("callx Widget SetRenderOpacity Transient+W_MapEditor+TimeGroup | f:" + (off ? "0" : "1"));
    if (!off)
        editorTimer = false;
}

void Say(const string &in text)
{
    messageAt = Host::Time();
    messageText.text = text;
    messageText.SetColor(1, 1, 1, 1);
}

void Warn(const string &in text)
{
    messageAt = Host::Time();
    messageText.text = text;
    messageText.SetColor(BAD_R, BAD_G, BAD_B, 1);
    Log::Warn(text);
}

// 12.345 s -> "00:12.345", like the game's own timer.
string FormatTime(double t)
{
    int ms = int(t * 1000);
    int m = ms / 60000;
    int s = (ms / 1000) % 60;
    int f = ms % 1000;
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s + "." + (f < 100 ? "0" : "") + (f < 10 ? "0" : "") + f;
}

// --- the checkpoints window ---------------------------------------------------------------------------------------
//
//   checkpoints                                              [close]
//   Map name · 3 checkpoints
//   +------------------------------------------------------------+
//   | export   [pcp1:12.5,0,L -3955 -1785 8717.8;R ...          ] |
//   |          click the box, ctrl+a, ctrl+c                       |
//   +------------------------------------------------------------+
//   | import   [paste a code here                              ] |
//   |          [add to mine] [replace mine]                        |
//   +------------------------------------------------------------+
//   | [clear this map]                                             |
//   +------------------------------------------------------------+
//   | cp 1   00:04.210   on the ground   3 tries   [go][^][v][x]  |   the list: scrolls when it's long
//   | cp 2   00:09.880   in the air      12 tries  [go][^][v][x]  |
//
// In the plugin manager's colours (the game's menus: near-black, lime for the main action). The mouse is on screen
// while it's open, which also keeps the practice keys off. The top part is the window's header (always shown); the
// list is its one view, emptied and filled again whenever the checkpoints change.

// Linear colours, the hex is what shows (see the plugin manager's menu).
const float WIN_R = 0.0052f, WIN_G = 0.0060f, WIN_B = 0.0086f;         // #101217 window
const float CARD_R = 0.0116f, CARD_G = 0.0137f, CARD_B = 0.0194f;      // #1c1f26 cards
const float BTN_R = 0.0232f, BTN_G = 0.0273f, BTN_B = 0.0382f;         // #2a2e37 buttons
const float MAIN_R = 0.0782f, MAIN_G = 0.2051f, MAIN_B = 0.0048f;      // #4f7d0f the main action
const float DANGER_R = 0.3185f, DANGER_G = 0.0232f, DANGER_B = 0.0232f; // #9a2a2a clearing
const float MUTED_R = 0.2582f, MUTED_G = 0.2747f, MUTED_B = 0.3185f;   // #8b8f99 hints
const float BOX_WIDTH = 640;

UI::Window@ window;
UI::Text@ windowInfo;
UI::TextInput@ exportBox;
UI::TextInput@ importBox;
UI::Button@ addButton;
UI::Button@ replaceButton;
UI::Button@ clearButton;
UI::Button@ closeButton;
bool importReplaces = false;
int listView = -1;

// The list's buttons, per row (the row is the checkpoint's index).
array<UI::Button@> goButtons;
array<UI::Button@> upButtons;
array<UI::Button@> downButtons;
array<UI::Button@> deleteButtons;
array<UI::TextInput@> nameBoxes;
array<UI::Button@> unnameButtons;
array<bool> nameFocused;            // each name box's focus last frame: leaving one saves what was typed

void BuildWindow()
{
    @window = UI::CreateWindow();
    window.SetAnchor(0.5f, 0.5f);
    window.SetPivot(0.5f, 0.5f);
    window.SetScreenSize(0.62f, 0.86f);
    window.SetBackground(WIN_R, WIN_G, WIN_B, 0.97f);
    window.SetCardBackground(CARD_R, CARD_G, CARD_B, 1);
    window.SetBlocksClicks(true);
    window.zOrder = 400;
    window.visible = false;

    window.StartHeader();
    window.AddText("checkpoints", 26);
    window.AddSpace(0);
    @closeButton = window.AddButton("close");
    closeButton.SetBackground(BTN_R, BTN_G, BTN_B, 1);
    window.NewRow();
    @windowInfo = Muted(window.AddText("", 15));

    window.StartCard();
    Label(window.AddText("export", 17));
    @exportBox = window.AddTextInput(BOX_WIDTH, "no checkpoints on this map yet", 14);
    exportBox.clearOnSubmit = false;
    exportBox.readOnly = true;          // selectable and copyable, not editable
    window.NewRow();
    window.AddSpace(90);
    Muted(window.AddText("click the box, ctrl+a, ctrl+c", 13));
    window.EndCard();

    window.StartCard();
    Label(window.AddText("import", 17));
    @importBox = window.AddTextInput(BOX_WIDTH, "paste a code here (ctrl+v), then a button", 14);
    importBox.clearOnSubmit = false;
    window.NewRow();
    window.AddSpace(90);
    @addButton = window.AddButton("add to mine");
    addButton.SetBackground(MAIN_R, MAIN_G, MAIN_B, 1);
    @replaceButton = window.AddButton("replace mine");
    replaceButton.SetBackground(BTN_R, BTN_G, BTN_B, 1);
    window.EndCard();

    window.StartCard();
    @clearButton = window.AddButton("clear this map");
    clearButton.SetBackground(DANGER_R, DANGER_G, DANGER_B, 1);
    window.AddSpace(0);
    Muted(window.AddText("deletes your checkpoints; the map's own are always there", 13));
    window.EndCard();

    listView = window.StartView();
    window.SetScrolling(listView, true);
    window.ShowView(listView);
}

UI::Text@ Muted(UI::Text@ t)
{
    t.SetColor(MUTED_R, MUTED_G, MUTED_B, 1);
    return t;
}

// The label column on the left of a card.
void Label(UI::Text@ t)
{
    t.SetWidth(90);
}

UI::Button@ RowButton(const string &in label, bool main = false)
{
    UI::Button@ b = window.AddButton(label);
    if (main)
        b.SetBackground(MAIN_R, MAIN_G, MAIN_B, 1);
    else
        b.SetBackground(BTN_R, BTN_G, BTN_B, 1);
    return b;
}

void BuildList()
{
    window.ClearView(listView);
    goButtons.resize(0);
    upButtons.resize(0);
    downButtons.resize(0);
    deleteButtons.resize(0);
    nameBoxes.resize(0);
    unnameButtons.resize(0);
    nameFocused.resize(0);
    for (uint i = 0; i < checkpoints.length(); i++)
    {
        Checkpoint@ cp = checkpoints[i];
        window.StartCard();
        UI::Text@ number = window.AddText("cp " + (i + 1), 17);
        number.SetWidth(64);
        if (int(i) == current)
            number.SetColor(LIVE_R, LIVE_G, LIVE_B, 1);
        // The host only hands over a box's text when it's submitted (Enter, or Submit when it loses focus), and never
        // empty text: "x" takes a name off. Without a name the "x" is blank and see-through, but still there: a hidden
        // widget takes no room, and the row's buttons would move when a name is added.
        UI::TextInput@ box = window.AddTextInput(130, "name", 14);
        box.clearOnSubmit = false;
        box.value = cp.name;
        nameBoxes.insertLast(box);
        nameFocused.insertLast(false);
        UI::Button@ unname = window.AddButton(cp.name != "" ? "x" : " ");
        unname.SetBackground(BTN_R, BTN_G, BTN_B, cp.name != "" ? 1 : 0);
        unnameButtons.insertLast(unname);
        window.AddText(FormatTime(cp.time), 16).SetWidth(100);
        Muted(window.AddText(cp.airborne ? "in the air" : "on the ground", 14)).SetWidth(110);
        UI::Text@ source = window.AddText(cp.fromMap ? "map checkpoint" : "", 14);
        source.SetWidth(110);
        source.SetColor(LIVE_R, LIVE_G, LIVE_B, 0.85f);
        Muted(window.AddText(cp.attempts == 0 ? "" : cp.attempts + (cp.attempts == 1 ? " try" : " tries"), 14)).SetWidth(80);
        window.AddSpace(0);
        goButtons.insertLast(RowButton("go", int(i) == current));
        upButtons.insertLast(RowButton("up"));
        downButtons.insertLast(RowButton("down"));
        deleteButtons.insertLast(RowButton("delete"));
        upButtons[i].visible = i > 0;
        downButtons[i].visible = i + 1 < checkpoints.length();
        window.EndCard();
    }
    if (checkpoints.length() == 0)
        Muted(window.AddText("no checkpoints yet: save one with " + SaveKey + " while racing", 15));
}

void OpenWindow()
{
    window.visible = true;
    UI::SetCursorVisible(true);
    RefreshWindow();
}

void CloseWindow()
{
    if (!window.visible)
        return;
    window.visible = false;
    UI::SetCursorVisible(false);
}

void RefreshWindow()
{
    if (window is null || !window.visible)
        return;
    string name = Editor::MapName() != "" ? Editor::MapName() : Race::TrackName();
    uint n = checkpoints.length();
    windowInfo.text = (name == "" ? "this map" : name) + "  ·  " + n + " checkpoint" + (n == 1 ? "" : "s") +
                      (mapKey == "" ? "  ·  not saved to disk (save the editor map first)" : "");
    exportBox.value = n == 0 ? "" : Encode(checkpoints);
    BuildList();
}

void UpdateWindow()
{
    // The window key opens and closes it, also while it's open (its boxes only have the keys while typing in them).
    if (Pressed(WindowKey) && (window.visible || !Editor::Typing()))
    {
        if (window.visible)
            CloseWindow();
        else
            OpenWindow();
    }
    if (!window.visible)
        return;
    if (closeButton.Clicked() || Input::Pressed(Input::Escape))
    {
        CloseWindow();
        return;
    }
    if (exportBox.Submitted())          // Enter in the export box: nothing to do
        RefreshWindow();
    if (addButton.Clicked())
    {
        importReplaces = false;
        importBox.Submit();
    }
    if (replaceButton.Clicked())
    {
        importReplaces = true;
        importBox.Submit();
    }
    if (importBox.Submitted())
    {
        Import(importBox.text, importReplaces);
        importReplaces = false;
    }
    if (clearButton.Clicked())
        ClearAll();
    UpdateList();
}

// One click at most per frame: every action rebuilds the list (through Persist), and with it these buttons.
void UpdateList()
{
    for (uint i = 0; i < nameBoxes.length(); i++)
    {
        if (nameBoxes[i].Submitted())
        {
            Rename(i, nameBoxes[i].text);
            return;
        }
        if (unnameButtons[i].Clicked())
        {
            Rename(i, "");
            return;
        }
        bool focused = nameBoxes[i].focused;
        if (nameFocused[i] && !focused)
            nameBoxes[i].Submit();      // clicked away: what was typed is kept, as with Enter
        nameFocused[i] = focused;
    }
    for (uint i = 0; i < goButtons.length(); i++)
    {
        if (goButtons[i].Clicked())
        {
            current = int(i);
            CloseWindow();
            if (inBall)
            {
                checkpoints[i].attempts++;
                GoTo(current);
            }
            return;
        }
        if (upButtons[i].Clicked() && i > 0)
        {
            Swap(i - 1, i);
            return;
        }
        if (downButtons[i].Clicked() && i + 1 < checkpoints.length())
        {
            Swap(i, i + 1);
            return;
        }
        if (deleteButtons[i].Clicked())
        {
            current = int(i);
            DeleteCurrent();
            return;
        }
    }
}

void Rename(uint i, const string &in raw)
{
    if (i >= checkpoints.length())
        return;
    string name = CleanName(raw);
    if (name == checkpoints[i].name)
        return;
    checkpoints[i].name = name;
    Persist();
}

void Swap(uint a, uint b)
{
    Checkpoint@ first = checkpoints[a];
    @checkpoints[a] = checkpoints[b];
    @checkpoints[b] = first;
    if (current == int(a))
        current = int(b);
    else if (current == int(b))
        current = int(a);
    Persist();
}

void Import(const string &in code, bool replace)
{
    array<Checkpoint@>@ list = Decode(code);
    if (list is null || list.length() == 0)
    {
        Warn("that isn't a checkpoint code");
        return;
    }
    if (replace)
        checkpoints.resize(0);
    for (uint i = 0; i < list.length(); i++)
        checkpoints.insertLast(list[i]);
    current = -1;
    importBox.value = "";
    Persist();
    Say(list.length() + " checkpoint" + (list.length() == 1 ? "" : "s") + " imported" + (replace ? " (replaced yours)" : ""));
}

// --- the map's own checkpoints --------------------------------------------------------------------------------------
//
// The map's checkpoints are MP_ActualCheckpoint_* actors (measured on a track editor map: MP_ActualCheckpoint_Strip_C,
// a strip on the floor with an arrow the way to go). The finish is another class (BP_Checkpoint_C, the ring), so it's
// never picked up. Each checkpoint becomes one of the player's where the game respawns the ball on it (measured: its
// Arrow component's location, 50 up, turned the way the arrow points), standing still. They have no number, so
// they're put in route order: the nearest to the start first, then the nearest to that one, and so on. Read through
// the console: the listing, then each arrow's location and rotation, then an end marker.

enum RingState { RingsIdle, RingsListing, RingsReading }
RingState ringState = RingsIdle;
double ringsSince = 0;
array<string> ringPaths;
array<array<double>@> ringSpots;     // per path: location, rotation (null until read)
array<array<double>@> ringTurns;
array<array<double>@> ringMins;       // per path: its colliding box (GetActorBounds), low and high corners
array<array<double>@> ringMaxs;
bool surveyForAdd = false;          // the survey was asked for by "add map checkpoints"
bool stripsReady = false;           // this map's strips have been surveyed
// Per path: its trigger (PreCheckpointAura1, the one part that only overlaps: measured), a scaled mesh box.
array<array<double>@> auraCenters;
array<array<double>@> auraTurns;
array<array<double>@> auraLows;     // the mesh's local box, not scaled
array<array<double>@> auraHighs;
array<array<double>@> auraScales;
int propsStrip = -1;                // the strip whose trigger's props are being read, or -1
const string AURA = ".PreCheckpointAura1";

const string RINGS_DONE = "callx GetActorTimeDilation(";          // the end marker, queued after each step
const double RESPAWN_ABOVE_ARROW = 50;                       // the game's respawn point: its arrow, this far up (measured)
const double SAME_SPOT = 150;                                   // a checkpoint this close is the same one

void StartSurvey(bool forAdd)
{
    if (forAdd)
        surveyForAdd = true;
    if (ringState != RingsIdle && Host::Time() - ringsSince < 5)
        return;
    ringState = RingsListing;
    ringsSince = Host::Time();
    ringPaths.resize(0);
    Send("instances Actor PersistentLevel+ActualCheckpoint");
    Send("callx BP_RollingBall_C GetActorTimeDilation");
}

// A log line while reading the map's checkpoints; true when it was one of theirs.
bool OnRingLine(const string &in body)
{
    if (ringState == RingsIdle)
        return false;
    if (ringState == RingsListing)
    {
        if (body.findFirst("instance ") == 0 && body.findFirst("ActualCheckpoint") >= 0)
        {
            ringPaths.insertLast(body.substr(9));
            return true;
        }
        if (body.findFirst(RINGS_DONE) == 0 || body.findFirst("no instance of Actor") == 0)
        {
            if (ringPaths.length() == 0)
            {
                ringState = RingsIdle;
                stripsReady = true;
                surveyForAdd = false;
                return true;
            }
            ringState = RingsReading;
            ringSpots.resize(0);
            ringTurns.resize(0);
            ringMins.resize(0);
            ringMaxs.resize(0);
            auraCenters.resize(0);
            auraTurns.resize(0);
            auraLows.resize(0);
            auraHighs.resize(0);
            auraScales.resize(0);
            propsStrip = -1;
            for (uint i = 0; i < ringPaths.length(); i++)
            {
                ringSpots.insertLast(null);
                ringTurns.insertLast(null);
                ringMins.insertLast(null);
                ringMaxs.insertLast(null);
                auraCenters.insertLast(null);
                auraTurns.insertLast(null);
                auraLows.insertLast(null);
                auraHighs.insertLast(null);
                auraScales.insertLast(null);
                Send("callx SceneComponent K2_GetComponentLocation " + ringPaths[i] + "+" + AURA);
                Send("callx SceneComponent K2_GetComponentRotation " + ringPaths[i] + "+" + AURA);
                Send("callx PrimitiveComponent GetLocalBounds " + ringPaths[i] + "+" + AURA);
                Send("props StaticMeshComponent " + ringPaths[i] + "+" + AURA);
                Send("callx Actor GetActorBounds " + ringPaths[i] + " | b:1");
                Send("callx SceneComponent K2_GetComponentLocation " + ringPaths[i] + "+.Arrow");
                Send("callx SceneComponent K2_GetComponentRotation " + ringPaths[i] + "+.Arrow");
            }
            Send("callx BP_RollingBall_C GetActorTimeDilation");
            return true;
        }
        return false;
    }
    // Reading: "callx GetActorBounds(...) on <path> ok Origin=<48 hex> BoxExtent=<48 hex>".
    if (body.findFirst("callx GetActorBounds(") == 0)
    {
        int i = ringPaths.find(CallTarget(body));
        array<double>@ middle = NamedVector(body, "Origin=");
        array<double>@ half = NamedVector(body, "BoxExtent=");
        if (i < 0 || middle is null || half is null)
            return i >= 0;
        array<double> low = {middle[0] - half[0], middle[1] - half[1], middle[2] - half[2]};
        array<double> high = {middle[0] + half[0], middle[1] + half[1], middle[2] + half[2]};
        @ringMins[i] = low;
        @ringMaxs[i] = high;
        return true;
    }
    // Reading: "callx K2_GetComponentLocation() -> 24 on <path>.Arrow ok ReturnValue=<48 hex>", the same for the
    // rotation, and for the trigger (<path>.PreCheckpointAura1).
    bool location = body.findFirst("callx K2_GetComponentLocation(") == 0;
    if (location || body.findFirst("callx K2_GetComponentRotation(") == 0)
    {
        string target = CallTarget(body);
        bool aura = EndsWith(target, AURA);
        if (aura)
            target = target.substr(0, target.length() - AURA.length());
        else if (EndsWith(target, ".Arrow"))
            target = target.substr(0, target.length() - 6);
        int i = ringPaths.find(target);
        if (i < 0)
            return false;               // not one of these (the markers' own reads)
        array<double>@ v = ReturnVector(body);
        if (aura && location)
            @auraCenters[i] = v;
        else if (aura)
            @auraTurns[i] = v;
        else if (location)
            @ringSpots[i] = v;
        else
            @ringTurns[i] = v;
        return true;
    }
    // "callx GetLocalBounds(min out: 24, max out: 24) on <path>.PreCheckpointAura1 ok min=<48 hex> max=<48 hex>"
    if (body.findFirst("callx GetLocalBounds(") == 0)
    {
        string target = CallTarget(body);
        int i = EndsWith(target, AURA) ? ringPaths.find(target.substr(0, target.length() - AURA.length())) : -1;
        if (i < 0)
            return false;
        @auraLows[i] = NamedVector(body, " min=");
        @auraHighs[i] = NamedVector(body, " max=");
        return true;
    }
    // "props of <path>.PreCheckpointAura1", then its lines: the one wanted is RelativeScale3D (the strip's own scale is
    // 1: the editor doesn't scale strips, it changes their parts).
    if (body.findFirst("props of ") == 0)
    {
        string target = body.substr(9);
        propsStrip = EndsWith(target, AURA) ? ringPaths.find(target.substr(0, target.length() - AURA.length())) : -1;
        return propsStrip >= 0;
    }
    if (propsStrip >= 0 && body.findFirst("  ") == 0)
    {
        if (body.findFirst("  RelativeScale3D (") == 0)
        {
            int at = body.findLast("= ");
            if (at >= 0)
                @auraScales[propsStrip] = NamedVector(body, "= ");
        }
        return true;
    }
    if (body.findFirst(RINGS_DONE) == 0)
    {
        ringState = RingsIdle;
        stripsReady = true;
        propsStrip = -1;
        AddMapCheckpoints();            // always: the map's checkpoints are always in the list
        surveyForAdd = false;
        return true;
    }
    return false;
}

void AddMapCheckpoints()
{
    // Where the route starts: the start if known, else where the ball is.
    array<double> from(3);
    if (spawn !is null)
        from = spawn.pos;
    else
        ReadLine(Race::SaveBall(), "L", from);
    array<uint> left;
    for (uint i = 0; i < ringSpots.length(); i++)
        if (ringSpots[i] !is null && !NearAny(ringSpots[i], left))
            left.insertLast(i);
    uint added = 0, skipped = 0, updated = 0;
    while (left.length() > 0)
    {
        uint best = 0;
        for (uint k = 1; k < left.length(); k++)
            if (Distance2(ringSpots[left[k]], from) < Distance2(ringSpots[left[best]], from))
                best = k;
        uint i = left[best];
        left.removeAt(best);
        array<double>@ at = ringSpots[i];
        from = at;
        double yaw = ringTurns[i] is null ? 0 : ringTurns[i][1];      // pitch, yaw, roll
        string state = "L " + Short(at[0]) + " " + Short(at[1]) + " " + Short(at[2] + RESPAWN_ABOVE_ARROW) +
                       "\nR 0 " + Short(yaw) + " 0\nV 0 0 0\nA 0 0 0\nC 350 " + Short(yaw) + " 0\n";
        // One made from this checkpoint before (maybe placed another way by an older version): put right, in place.
        int old = NearMapCheckpoint(at);
        if (old >= 0)
        {
            checkpoints[old].state = state;
            ReadLine(state, "L", checkpoints[old].pos);
            checkpoints[old].airborne = false;
            updated++;
            continue;
        }
        if (NearCheckpoint(at))
        {
            skipped++;
            continue;
        }
        Checkpoint@ cp = Checkpoint();
        cp.state = state;
        ReadLine(state, "L", cp.pos);
        cp.fromMap = true;
        checkpoints.insertLast(cp);
        added++;
    }
    Persist();
    if (added > 0)
        Say(added + " map checkpoint" + (added == 1 ? "" : "s") + " added");
}

// Another of the map's checkpoints already in the list, this close (some are made of two actors in one spot).
bool NearAny(const array<double>@ at, const array<uint>@ picked)
{
    for (uint k = 0; k < picked.length(); k++)
        if (Distance2(ringSpots[picked[k]], at) < SAME_SPOT * SAME_SPOT)
            return true;
    return false;
}

// A map checkpoint of the player's made from the one at `at` (within a strip's length): its index, or -1.
const double MAP_SAME = 400;

int NearMapCheckpoint(const array<double>@ at)
{
    for (uint k = 0; k < checkpoints.length(); k++)
        if (checkpoints[k].fromMap && Distance2(checkpoints[k].pos, at) < MAP_SAME * MAP_SAME)
            return int(k);
    return -1;
}

// One of the player's checkpoints there already (the button pressed twice).
bool NearCheckpoint(const array<double>@ at)
{
    for (uint k = 0; k < checkpoints.length(); k++)
        if (Distance2(checkpoints[k].pos, at) < SAME_SPOT * SAME_SPOT)
            return true;
    return false;
}

double Distance2(const array<double>@ a, const array<double>@ b)
{
    double x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2];
    return x * x + y * y + z * z;
}

// "callx Fn(...) -> 24 on <path> ok ...": the object it ran on.
string CallTarget(const string &in body)
{
    int on = body.findFirst(" on ");
    if (on < 0)
        return "";
    int end = body.findFirst(" ", on + 4);
    return end < 0 ? "" : body.substr(on + 4, end - on - 4);
}

// "... Name=<48 hex digits>": three little-endian doubles, or null.
array<double>@ NamedVector(const string &in body, const string &in name)
{
    int at = body.findFirst(name);
    if (at < 0 || int(body.length()) < at + int(name.length()) + 48)
        return null;
    array<double> v(3);
    for (int i = 0; i < 3; i++)
        v[i] = HexDouble(body, at + int(name.length()) + i * 16);
    return v;
}

// "... ok ReturnValue=<48 hex digits>": three little-endian doubles (a vector or a rotator), or null.
array<double>@ ReturnVector(const string &in body)
{
    int at = body.findFirst("ReturnValue=");
    if (at < 0 || body.findFirst(" ok ") < 0 || int(body.length()) < at + 12 + 48)
        return null;
    array<double> v(3);
    for (int i = 0; i < 3; i++)
        v[i] = HexDouble(body, at + 12 + i * 16);
    return v;
}

double HexDouble(const string &in s, int at)
{
    uint64 bits = 0;
    for (int b = 7; b >= 0; b--)
        bits = (bits << 8) | uint64(HexDigit(s[at + b * 2]) * 16 + HexDigit(s[at + b * 2 + 1]));
    bool negative = (bits >> 63) != 0;
    int exponent = int((bits >> 52) & 0x7FF);
    uint64 mantissa = bits & ((uint64(1) << 52) - 1);
    if (exponent == 0 && mantissa == 0)
        return 0;
    double fraction = double(mantissa) / 4503599627370496.0;      // 2^52
    double value = exponent == 0 ? fraction * Pow2(-1022) : (1 + fraction) * Pow2(exponent - 1023);
    return negative ? -value : value;
}

double Pow2(int n)
{
    double r = 1;
    for (; n > 0; n--) r *= 2;
    for (; n < 0; n++) r *= 0.5;
    return r;
}

// --- keys ---------------------------------------------------------------------------------------------------------

bool Pressed(const string &in name)
{
    int code = KeyCode(name);
    return code > 0 && Input::Pressed(Input::Key(code));
}

bool Held(const string &in name)
{
    int code = KeyCode(name);
    return code > 0 && Input::Down(Input::Key(code));
}

// "F5", "g", " 7 ", "Space", "MouseMiddle"... as a Windows virtual key code, or 0 when it isn't a key Input knows.
int KeyCode(const string &in raw)
{
    string name = Upper(Trim(raw));
    if (name.length() == 1)
    {
        uint8 c = name[0];
        if ((c >= 65 && c <= 90) || (c >= 48 && c <= 57))
            return c;
        return 0;
    }
    if (name.length() <= 3 && name[0] == 70)        // F1..F12
    {
        int n = int(parseInt(name.substr(1)));
        return n >= 1 && n <= 12 ? 0x6F + n : 0;
    }
    array<string> names = {"SPACE", "ENTER", "TAB", "SHIFT", "CTRL", "ALT", "LEFT", "UP", "RIGHT", "DOWN",
                           "MOUSELEFT", "MOUSERIGHT", "MOUSEMIDDLE", "BACKSPACE", "DELETE",
                           "PADA", "PADB", "PADX", "PADY", "PADLB", "PADRB", "PADLT", "PADRT", "PADL3", "PADR3",
                           "PADVIEW", "PADMENU", "PADUP", "PADDOWN", "PADLEFT", "PADRIGHT"};
    array<int> codes = {0x20, 0x0D, 0x09, 0x10, 0x11, 0x12, 0x25, 0x26, 0x27, 0x28, 0x01, 0x02, 0x04, 0x08, 0x2E,
                        0x100, 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107, 0x108, 0x109,
                        0x10A, 0x10B, 0x10C, 0x10D, 0x10E, 0x10F};
    int i = names.find(name);
    return i >= 0 ? codes[i] : 0;
}

string Trim(const string &in s)
{
    int first = s.findFirstNotOf(" \t");
    if (first < 0)
        return "";
    int last = s.findLastNotOf(" \t");
    return s.substr(first, last - first + 1);
}

string Upper(const string &in s)
{
    string r = s;
    for (uint i = 0; i < r.length(); i++)
        if (r[i] >= 97 && r[i] <= 122)
            r[i] = uint8(r[i] - 32);
    return r;
}
