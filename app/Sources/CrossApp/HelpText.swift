import Foundation

/// The hover help (SwiftUI `.help`) of every control, in plain language for a gamer who
/// knows nothing about Wine. One constant per text, named after its view and control,
/// grouped by view (docs/app.md > Hover help lists them all). Multi-line literals use `\`
/// line continuations, so a text has no line breaks except an explicit `\n`.
enum HelpText {
    // MARK: - BottleView: header

    static let graphicsPicker = """
        Which translation layer draws the game. D3DMetal (default) handles DirectX 11 and 12 \
        games. wined3d is Wine's own, slower renderer. DXVK and DXMT are alternatives for \
        DirectX 9/10/11 games that misbehave on D3DMetal (DXVK needs the winecx-full runtime). \
        Applies to programs started afterwards; for Steam games, restart Steam.
        """
    static let showC = """
        Opens this bottle's C: drive in Finder, where its programs and save files live.
        """

    // MARK: - BottleView: actions box

    static let runExe = """
        Picks a Windows program or installer and runs it in this bottle (⌘O). A game bought \
        on Steam starts through Steam.
        """
    static let exeArguments = """
        Extra command-line options for the program you run with Run .exe…, for example \
        -windowed. Leave it empty unless a game's guide tells you to add one.
        """
    static let killBottle = """
        Force-quits every Windows program in this bottle, including Steam. The way out of a \
        stuck game. Unsaved progress is lost.
        """
    static let wineConfiguration = """
        Opens Wine's settings for this bottle: the Windows version it pretends to be, drives \
        and per-program overrides. Rarely needed.
        """
    static let commandPrompt = """
        Opens a Windows command window inside this bottle, for typing commands as you would \
        on a PC.
        """
    static let explorer = "Opens a Windows-style file browser for this bottle's drives."
    static let commandLine = """
        One Windows command to run in this bottle, for example ver or ipconfig. Its output \
        appears in the log below.
        """
    static let runCommand = """
        Runs the command on the left in this bottle; the output appears in the log below.
        """

    // MARK: - BottleView: disk row

    static let diskUsage = """
        How much of this bottle's own disk is in use. Windows sees C: as a drive of this \
        size; Change… resizes it.
        """
    static let diskFolder = """
        This bottle is a plain folder on the Mac's disk and grows as needed. Move to a Disk \
        Image… gives it a fixed size instead.
        """
    static func diskLocation(_ path: String) -> String {
        "Where this bottle's files are kept:\n\(path)"
    }
    static let moveMenu = """
        Moves this bottle to another folder or drive, e.g. an external SSD, or back to the \
        bottles folder. It is copied and checked before the original is removed, so nothing \
        is lost. Close its programs first.
        """
    static let moveChooseFolder = """
        Picks the folder or drive to move this bottle to. It then runs from there while the \
        drive is connected.
        """
    static let moveBottlesFolder = "Moves the bottle back to Gamify's bottles folder on this Mac."
    static let moveEject = """
        Unmounts this bottle's disk image so the drive can be ejected safely. Click Mount on \
        the bottle's page to use it again.
        """
    static let changeSize = """
        Changes how much space this bottle may take. Windows sees C: as a drive of that size. \
        Close its programs first.
        """
    static let moveToImage = """
        Puts this bottle into its own disk image with a size limit you choose, like a virtual \
        drive. The image only takes the space actually used.
        """

    // MARK: - BottleView: unavailable box

    static let mount = "Mounts this bottle's disk image again so it can be used."
    static let tryAgain = "Checks again whether the bottle's drive or disk image is available now."
    static let removeFromList = """
        Takes the bottle off the list. Its files stay on the drive; Find Bottles… can add it \
        back later.
        """

    // MARK: - BottleView: stores box

    static let steamStatus = """
        Whether Steam is installed in this bottle, running and signed in. Checked every few \
        seconds.
        """
    static let installSteam = """
        Downloads Steam's official installer (once) and installs Steam in this bottle. Steam \
        then starts once to download its client, about 1.7 GB; a black window during that is \
        normal.
        """
    static let steamSettingUp = """
        Steam is downloading its client and will restart once by itself. This takes a few \
        minutes; the log below shows the progress.
        """
    static let steamRestarting = """
        Steam is being closed and started again. Takes up to half a minute.
        """
    static let launchSteam = """
        Starts Steam in this bottle. If Steam is already running but stuck, Gamify offers to \
        restart it first.
        """
    /// ↻ Restart, and Restart Steam on the stuck row.
    static let restartSteam = """
        Quits Steam and starts it again cleanly. Use it when Steam shows "No connection", \
        hangs, or a game will not start. Also needed after changing Graphics or Performance \
        settings, so Steam games pick them up. Nothing is lost.
        """
    static let checkSteam = """
        Asks Steam whether it is signed in and whether your games get their licences from it, \
        and lists each installed game's licence (bought, Friend's Pass, free weekend…). Use it \
        when a game runs as a demo or trial.
        """
    static func storeStatus(_ store: String) -> String {
        "Whether \(store) is installed in this bottle and running right now."
    }
    static func storeKnownIssue(_ issue: String) -> String {
        "Known issue: \(issue)"
    }
    static func storeLaunch(_ store: String) -> String {
        "Starts \(store) in this bottle. On its first start a store may update itself and restart once."
    }
    static func storeInstall(_ store: String) -> String {
        """
        Downloads \(store)'s official installer (once, kept in Gamify's Downloads folder) and \
        installs it in this bottle. You are asked first.
        """
    }

    // MARK: - BottleView: processes box

    /// A row in the list (not in the audit: the row itself is clickable).
    static let jobRow = "Click to show this program's log below."
    static let jobStop = """
        Asks this program to quit. If it does not, Kill Bottle ends everything in the bottle.
        """
    static let jobLog = "Shows this program's log file in Finder. Attach it when asking for help."

    // MARK: - BottleView: performance box

    static let perfSync = """
        How Windows programs wait for each other. ESync works everywhere; MSync is sometimes \
        faster in games. Switch only if a game stutters, and only while nothing runs in this \
        bottle.
        """
    static let perfMetalFX = """
        Games that offer DLSS in their settings get Apple's MetalFX upscaling instead, and \
        frame generation on macOS 26 or newer. Leave it on unless a game shows a \
        graphics-driver warning. For Steam games, restart Steam after changing it.
        """
    static let perfMetalFXDisabled = """
        DLSS via MetalFX needs the D3DMetal graphics backend. Pick D3DMetal above to use it.
        """
    static let perfAVX = """
        Tells games this Mac supports AVX, a set of CPU instructions some newer games require. \
        Turn it on only if a game refuses to start with a message about AVX or an unsupported \
        CPU.
        """
    static let perfRayTracing = """
        Lets DirectX 12 games use ray tracing (realistic lighting and reflections) through \
        D3DMetal. Default: on with an M3 chip or newer. Set it Off when a game turns ray \
        tracing on by itself and runs slowly.
        """
    static let perfFPSCap = """
        Limits the frame rate, for example 60. Steadier, cooler and quieter, and a good match \
        for frame generation. Leave it empty for no limit.
        """
    static let perfHUD = """
        Shows Apple's performance overlay in the game window: frame rate, GPU time and whether \
        MetalFX is active. Useful while tuning, off for playing.
        """
    static let perfRetina = """
        Renders at the display's full resolution. Sharper, but roughly four times the pixels, \
        so lower frame rates. Off scales a half-resolution image up, which is what most games \
        want. Change it only while nothing runs in this bottle.
        """

    // MARK: - BottleView: StorageSizeField

    static let storageSize = """
        The size Windows sees for this bottle's C: drive, in GB. The disk image only takes the \
        space actually used, so a generous size costs nothing until it is filled.
        """

    // MARK: - BottleView: StorageSheet

    static let storageResize = """
        Applies the new size. Takes a few seconds; programs in the bottle must be closed.
        """
    static let storageMove = """
        Copies the bottle into a new disk image of this size and removes the folder once the \
        copy is verified.
        """
    static let storageToFolder = """
        Turns the bottle back into a plain folder that can grow as large as the Mac's disk \
        allows. Folder bottles cannot live on exFAT drives.
        """

    // MARK: - CrossApp: ContentView

    static let newBottle = """
        Creates a new bottle: a separate Windows installation with its own C: drive, settings \
        and programs.
        """
    static let findBottles = """
        Searches connected drives, or a folder you choose, for bottles that are not in the \
        list, e.g. one made on another Mac.
        """
    static let sidebarShowInFinder = "Opens the bottle's folder in Finder."
    static let sidebarEject = """
        Unmounts this bottle's disk image so its drive can be ejected safely. Click Mount on \
        the bottle's page to use it again.
        """
    static let sidebarRemoveFromList = """
        Takes the bottle off the list but keeps its files. Find Bottles… adds it back.
        """
    static let sidebarDelete = """
        Deletes the bottle with everything installed in it. Cannot be undone.
        """

    // MARK: - CrossApp: BottleRow

    static let bottleRowSubtitle = """
        Wine build · graphics backend · size of its own disk · where it is kept.
        """

    // MARK: - CrossApp: FoundBottlesBanner

    static let foundReview = "Shows the bottles found on the drive so you can add them to the list."
    static let foundDismiss = "Hides this notice. Find Bottles… below finds them again later."

    // MARK: - CrossApp: NewBottleSheet

    static let newBottleName = """
        The bottle's name, also the name of its folder. Cannot start with a dot or contain a \
        slash.
        """
    static let newBottleRuntime = """
        Which Wine build the bottle uses. winecx-full adds video playback, SDL2 and Vulkan \
        support (needed for DXVK); winecx is the plain build. Cannot be changed later.
        """
    static let newBottleGraphics = """
        Which translation layer draws the game. D3DMetal (default) handles DirectX 11 and 12 \
        games. wined3d is Wine's own, slower renderer. DXVK and DXMT are alternatives for \
        DirectX 9/10/11 games that misbehave on D3DMetal (DXVK needs the winecx-full runtime). \
        You can change this later on the bottle page.
        """
    static let newBottleLocation = """
        Where the bottle's files are kept: Gamify's bottles folder on this Mac, or a folder \
        you choose, e.g. on an external drive.
        """
    static let newBottleChooseLocation = """
        Picks a folder, e.g. on an external SSD, to keep the bottle there. It runs from there \
        while the drive is connected.
        """
    static let newBottleDisk = """
        Its own disk: a virtual disk of a fixed size, so the bottle can never take more; the \
        image only takes the space actually used. Unlimited: a plain folder that grows as \
        needed (not possible on exFAT drives).
        """
    static let newBottleCreate = "Creates the bottle and sets up its C: drive (about 40 seconds)."

    // MARK: - SettingsView: GeneralTab

    static let tutorialShowAgain = """
        Opens the first-run introduction again (bottles, Steam, running games).
        """
    static let tutorialShowOnNextLaunch = """
        Makes the tutorial open again the next time Gamify starts.
        """

    // MARK: - Updates: UpdateSettingsSection (Settings > General)

    static let updatesCheckOnLaunch = """
        Looks for a new Gamify version each time the app starts. Only a small version file is \
        fetched; nothing about you or your Mac is sent.
        """
    static let updatesAutoInstall = """
        Downloads and installs a new version by itself when one is found, then restarts \
        Gamify. An update that replaces the Wine runtime is skipped while a game or Steam is \
        running; quit them and check again.
        """
    static let updatesCheckNow = "Looks for a new version right now."
    static let updatesRuntimeVersion = """
        The version of the Wine runtime bundled with Gamify. "not versioned" means Gamify runs \
        from a source checkout.
        """

    // MARK: - SettingsView: EnvironmentTab

    static let envBottle = "The bottle whose environment to show."
    static let envOnlyGamify = """
        Shows only the settings Gamify adds for this bottle, not everything the Mac passes on \
        to programs.
        """
    static let envExport = """
        Formats the list so it can be pasted into Terminal to run the bottle by hand (each \
        line starts with export).
        """
    static let envCopy = "Copies the list to the clipboard, e.g. to attach to a bug report."

    // MARK: - SettingsView: PathsTab

    /// The reveal arrow in every path row (also the tutorial's location rows).
    static let showInFinder = "Show in Finder"
    static let pathsChooseBottles = """
        Picks a different folder for all bottles, e.g. on a bigger drive. Bottles in the old \
        folder are not listed until you move them there or reset this.
        """
    static let pathsResetBottles = "Goes back to Gamify's standard bottles folder."
    static let pathsRosetta = """
        Apple's translator that runs Intel programs on Apple Silicon. Windows games need it.
        """
    static let pathsRuntimes = """
        The Wine builds that come with Gamify. Each bottle uses one of them.
        """
    static let pathD3DMetal = """
        Apple's layer that turns DirectX 11 and 12 into Metal; the default graphics backend.
        """
    static let pathWined3d = "Wine's own DirectX renderer, the fallback graphics backend."
    static let pathDXVK = """
        Graphics backend for DirectX 9/10/11 over Vulkan; an alternative when a game \
        misbehaves on D3DMetal.
        """
    static let pathDXMT = """
        Graphics backend for DirectX 10/11 directly on Metal; an alternative when a game \
        misbehaves on D3DMetal.
        """
    static let pathWebhelper = """
        A small helper that lets Steam's store and library pages render under Wine.
        """
    /// The root override field, its Choose… and Apply (source checkout only).
    static let pathsRootOverride = """
        For developers: where the Gamify source checkout is. Leave it empty.
        """

    // MARK: - ProgramsView

    static let programsInstall = """
        Runs a Windows installer (.exe or .msi) in this bottle, as on a PC. The programs it \
        installs appear in this list afterwards.
        """
    static let programsAdd = """
        Adds a program that is already inside this bottle's C: drive to this list, so you can \
        launch it from here.
        """
    /// The caption under a program's name: its exe, and the shortcut it came from.
    static func programPath(_ exe: String, shortcut: String?) -> String {
        exe + (shortcut.map { "\nShortcut: \($0)" } ?? "")
    }
    static let programLaunch = """
        Runs this program in the bottle. A Steam game starts through Steam, so Steam counts \
        the licence and playtime.
        """
    static let programMenu = """
        More options. Clear Shader Cache… deletes the graphics shaders compiled for this \
        program; try it when a game stops starting or shows glitches after an update.
        """
    static let programClearShaderCache = """
        Deletes the shaders D3DMetal compiled for this program. The next start compiles them \
        again (a slower first start, some stutter). Apple recommends this when a game no \
        longer starts after an update.
        """
    static let programRemoveShortcut = """
        Remove from this list (the shortcut and the program stay in the bottle)
        """
    static let programRemove = "Remove from this list (the program stays in the bottle)"
    static let addProgramName = "The name shown in the Programs list."
    static let addProgramArguments = """
        Extra command-line options passed to the program every time it is launched from here. \
        Usually empty.
        """
    static let addProgramAdd = "Adds the program to the list."

    // MARK: - SteamCheckView

    static let steamCheckCopy = """
        Copies the whole report as text, to paste into a message when asking for help.
        """
    static let steamCheckAgain = "Runs the check again, e.g. after signing in to Steam."

    // MARK: - FindBottlesView

    static let findSearchDrives = """
        Searches every connected drive again, e.g. after plugging one in.
        """
    static let findSearchFolder = """
        Searches one folder you choose, e.g. a network share or a specific place on a drive.
        """
    static let findName = """
        The name the bottle gets in the list. Change it if the name is already taken.
        """
    static let findAdd = "Adds this bottle to the list. It stays where it is and runs from there."
    static let findListed = "This bottle is already in the list under this name."

    // MARK: - TutorialView

    static let tutorialSkip = "Closes the tutorial. Help > Gamify Tutorial opens it again any time."
    static let tutorialBack = "Goes to the previous step."
    static let tutorialNext = "Goes to the next step."
    static let tutorialFinish = """
        Closes the tutorial. Help > Gamify Tutorial opens it again any time.
        """
    static let tutorialInstallRosetta = """
        Runs Apple's installer for Rosetta 2. macOS asks for your password; the download is \
        about 300 MB.
        """
    static let tutorialCopyCommand = "Copies the Terminal command to the clipboard."
    static let tutorialCheckRosetta = "Checks whether Rosetta 2 is installed now."
    static let tutorialBottlePicker = "The bottle the next steps use for Steam and games."
    static let tutorialName = "The new bottle's name. Cannot start with a dot or contain a slash."
    static let tutorialCreateBottle = """
        Creates the bottle with the standard settings (D3DMetal, its own disk). About 40 \
        seconds.
        """
    static let tutorialInstallSteam = """
        Downloads Steam's official installer and sets Steam up in this bottle; takes a few \
        minutes. Sign in when Steam's window appears.
        """
    static let tutorialLaunchSteam = "Starts Steam in this bottle."
    static let tutorialOpenSettings = "Opens Gamify's settings: folders, updates and this tutorial."

    // MARK: - Updates: UpdateBanner

    static let updateReleaseNotes = "Opens what changed in this version in your browser."
    static let updateLater = "Hides the notice. Gamify offers the update again on the next launch."
    static let updateInstallNow = """
        Downloads the update, installs it and restarts Gamify. Your bottles and games stay as \
        they are.
        """
    static let updateCancel = "Stops the download. The update is offered again later."
}
