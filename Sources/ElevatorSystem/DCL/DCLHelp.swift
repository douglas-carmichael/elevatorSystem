import Foundation

// HELP and SELFTEST.
extension DCLEngine {
    func helpText(topic: String?) -> String {
        if let t = topic {
            return helpTopic(t)
        }
        var s = "\n  HELP topic\n  ---- -----\n"
        s += "Available topics:\n\n"
        s += "  @COMMAND      ACCOUNTING    ACKNOWLEDGE   ALLOCATE      ANALYZE\n"
        s += "  APPEND        ASSIGN        ATTACH        BACKUP        CALL\n"
        s += "  CLEAR         CLOSE         CONTINUE      COPY          CREATE\n"
        s += "  DEALLOCATE    DEASSIGN      DEFINE        DELETE        DIFFERENCES\n"
        s += "  DIRECTORY     DISMOUNT      EDIT          ELEVATOR      EXAMINE\n"
        s += "  EXIT          FINGER        GOTO          HELP          IF\n"
        s += "  INSTALL       LOGOUT        MAIL          MONITOR       MOUNT\n"
        s += "  PHONE         PRINT         PRODUCT       PURGE         RECALL\n"
        s += "  RENAME        REPLY         REQUEST       RUN           SCRIPTING\n"
        s += "  SEARCH        SET           SHOW          SPAWN         STOP\n"
        s += "  SUBMIT        TUTORIAL      TYPE          WAIT          WRITE\n\n"
        s += "Privileged verbs (refused for the operator account):  DEPOSIT, INITIALIZE, PATCH\n\n"
        s += "Type HELP <topic> for details. Commands may be abbreviated\n"
        s += "(e.g. SH PROC == SHOW PROCESS, DEAL == DEALLOCATE).\n"
        return s
    }

    func helpTopic(_ raw: String) -> String {
        let t = raw.uppercased()
        switch true {
        case matches(t, "SHOW"):
            var s = "\n  SHOW <subcommand>\n"
            s += "      PROCESS [/ALL]   SYSTEM         USERS          DEVICES\n"
            s += "      MEMORY           TIME           NETWORK        QUEUE\n"
            s += "      ALARMS           DISPATCH         CALLS\n"
            s += "      LOGICAL [/PROC]\n"
            s += "      SYMBOL [name]    ERROR            STATUS\n"
            s += "      LICENSE          CPU            DEFAULT        QUOTA\n"
            s += "      PROTECTION       TERMINAL       WORKING_SET    VERSION\n"
            s += "      RMS_DEFAULT      INTRUSION      CLUSTER        CONNECTIONS\n"
            s += "      AUDIT\n"
            return s
        case matches(t, "ACKNOWLEDGE", min: 3):
            var s = "\n  ACKNOWLEDGE ALARM <id>\n"
            s += "  ACKNOWLEDGE ALARM ALL\n"
            s += "      Mark one active SCADA alarm, or every active alarm, as seen by\n"
            s += "      the operator. Alarm history is shown with SHOW ALARMS.\n"
            return s
        case matches(t, "SET"):
            var s = "\n  SET <subcommand>\n"
            s += "      DEFAULT [device:][directory]\n"
            s += "      TERMINAL/WIDTH=n /PAGE=n\n"
            s += "      PROMPT=\"text\"\n"
            s += "      PROCESS/PRIORITY=n /NAME=name\n"
            s += "      PASSWORD\n"
            s += "      CAB <label> /MANUAL | /AUTOMATIC      <-- demo manual control\n"
            s += "      CAB <label> /PAX | /FREIGHT           <-- set cab profile\n"
            s += "      ON, NOON, VERIFY, NOVERIFY\n"
            return s
        case matches(t, "CALL"):
            var s = "\n  CALL CAB <label> FLOOR <n>\n"
            s += "      Queue a floor call on the named cab. Bypasses the group\n"
            s += "      dispatcher -- the named cab serves the call directly.\n"
            s += "      Models an in-cab \"car call\" -- the rider is already onboard.\n"
            s += "\n  CALL HALL /FLOOR=<n> /UP | /DOWN\n"
            s += "      Models a landing-fixture button press. Registered as a\n"
            s += "      world-level hall call (SHOW CALLS) and allocated to the\n"
            s += "      nearest cab travelling in the requested direction; the\n"
            s += "      lantern extinguishes when a cab arrives.\n"
            s += "\n  CALL DESTINATION /FROM=<n> /TO=<m>\n"
            s += "      Destination-dispatch entry point. The group dispatcher picks\n"
            s += "      the cab with the lowest ETA to <n> (with a small same-direction\n"
            s += "      bias) and pre-loads its queue with origin then destination so\n"
            s += "      the rider is picked up first and dropped off second.\n"
            s += "      Requires  SET BUILDING /DISPATCH=DESTINATION  for the auto-\n"
            s += "      driver to stand down and let the allocator manage every trip.\n"
            return s
        case matches(t, "OPEN"):
            return "\n  OPEN CAB <label>               Request the cab's doors to open.\n"
        case matches(t, "CLOSE"):
            return "\n  CLOSE CAB <label>              Request the cab's doors to close.\n"
        case matches(t, "STOP"):
            return "\n  STOP CAB <label>               Clear the cab's queued floor calls.\n"
        case matches(t, "MONITOR"):
            var s = "\n  MONITOR <class> [/INTERVAL=seconds]\n"
            s += "      Continuous full-screen display, refreshed every INTERVAL\n"
            s += "      seconds (default 3).  Press Ctrl/Y (or ESC ESC over\n"
            s += "      a telnet client) to interrupt and return\n"
            s += "      to the DCL prompt.\n\n"
            s += "  Available classes:\n"
            s += "      SYSTEM         Mode breakdown + I/O + page rates\n"
            s += "      MODES          Time spent in each processor access mode\n"
            s += "      PROCESSES      Top CPU-time processes (bar chart)\n"
            s += "      IO             I/O subsystem rates\n"
            s += "      PAGE           Page management rates and free/modified list size\n"
            s += "      STATES         Process scheduling-state counts\n"
            s += "      DISK           Per-disk operation rates\n"
            s += "      LOCK           Distributed lock manager rates\n"
            s += "      CLUSTER        Per-node CPU/IO/memory summary\n"
            s += "      FCP            Files-11 XQP primitive rates\n"
            s += "      DYNAMICS       Live cab dynamics (position / vel / accel / state) -- LPD\n"
            s += "      ALL_CLASSES    Concatenation of SYSTEM + IO + STATES\n"
            return s
        case matches(t, "ELEVATOR"):
            var s = "\n  Elevator demo flow:\n"
            s += "    SET CAB L02 /MANUAL         ! Disable auto-driver for cab L02\n"
            s += "    CALL CAB L02 FLOOR 7        ! Drive it to floor 7\n"
            s += "    OPEN CAB L02                ! Open the doors\n"
            s += "    CLOSE CAB L02               ! Close the doors\n"
            s += "    STOP CAB L02                ! Cancel any pending calls\n"
            s += "    SET CAB L02 /AUTOMATIC      ! Hand control back to the auto-driver\n"
            s += "    SET CAB L02 /FREIGHT        ! Designate as freight cab\n"
            s += "    SET CAB L02 /PAX            ! Designate as passenger cab\n"
            return s

        case matches(t, "ALLOCATE", min: 3):
            return "\n  ALLOCATE device:\n      Claim a user-class device (tape, scratch disk, terminal)\n      for the current process. System volumes are refused.\n"
        case matches(t, "DEALLOCATE", min: 5):
            return "\n  DEALLOCATE device:    or   DEALLOCATE/ALL\n      Release a previously allocated device, or release everything\n      this process has claimed.\n"
        case matches(t, "MOUNT"):
            return "\n  MOUNT device: [volume-label]\n      Attach a volume to a device. The volume label defaults to\n      SCRATCH if not given. System volumes are refused.\n"
        case matches(t, "DISMOUNT", min: 4):
            return "\n  DISMOUNT device:\n      Detach a previously mounted volume.\n"
        case matches(t, "BACKUP"):
            var s = "\n  BACKUP input-spec output-spec\n"
            s += "      Copy a save-set. Prints the OpenVMS BACKUP IDENT banner,\n"
            s += "      a verification line, and the standard CREATED / COPIED messages.\n"
            s += "      Example:  BACKUP CAB$DATA: MUA0:ELEV.BCK\n"
            return s
        case matches(t, "ANALYZE", min: 4):
            var s = "\n  ANALYZE/ERROR_LOG          Recent error log entries.\n"
            s +=   "  ANALYZE/AUDIT              Security audit characteristics.\n"
            s +=   "  ANALYZE/IMAGE              (Privileged) image structure analysis.\n"
            s +=   "  ANALYZE/CRASH_DUMP         (Privileged) read SYS$SYSTEM:SYSDUMP.DMP.\n"
            return s
        case matches(t, "RUN"):
            var s = "\n  RUN image-name\n"
            s += "      Execute an installed image.  Operator account can run the\n"
            s += "      diagnostic images:\n"
            s += "        BRAKE_TEST       Brake hold-force test on every cab.\n"
            s += "        DOOR_TEST        Door open/close + obstruction sensor test.\n"
            s += "        WEIGHT_CAL       Load-cell zero / span calibration.\n"
            s += "        HALL_LAMP_TEST   Cycle every hall-call lamp UP/DOWN.\n"
            s += "      Other images return %SYSTEM-F-NOPRIV.\n"
            return s
        case matches(t, "EXAMINE", min: 4):
            return "\n  EXAMINE address\n      Display the longword stored at the given virtual address.\n      Hex addresses may be entered as ^X1000 or 1000.\n"
        case matches(t, "REPLY"):
            return "\n  REPLY \"text\"\n      Queue a reply line to the operator console (OPA0:).\n"
        case matches(t, "REQUEST", min: 4):
            return "\n  REQUEST \"text\"\n      Log an operator-assistance request through OPCOM.\n"

        case matches(t, "DIRECTORY", min: 3):
            return "\n  DIRECTORY [filespec] [/SIZE] [/DATE] [/FULL]\n      List files in the default directory. /SIZE adds the\n      used/allocated block columns; /DATE adds the timestamp.\n"
        case matches(t, "TYPE"):
            return "\n  TYPE filename\n      Print the contents of a sequential ASCII file. User-created\n      .COM files round-trip through the on-disk script store;\n      binary files (PEERS.DAT) return %TYPE-W-NOTASCII.\n"
        case matches(t, "WRITE"):
            return "\n  WRITE SYS$OUTPUT \"text\"\n      Echo a literal string. Other destinations return WRITERR.\n"
        case matches(t, "ASSIGN"):
            return "\n  ASSIGN equiv-name logical-name\n      Add an entry to the process logical-name table. (DEFINE\n      uses the reverse argument order: DEFINE name equiv.)\n"
        case matches(t, "DEFINE"):
            return "\n  DEFINE logical-name equiv-name\n      Define a process logical name. Same effect as ASSIGN with\n      arguments reversed.\n"
        case matches(t, "DEASSIGN"):
            return "\n  DEASSIGN logical-name\n      Remove a process logical name. Returns %SYSTEM-F-NOLOGNAM\n      if the name is not defined.\n"
        case matches(t, "RECALL", min: 3):
            return "\n  RECALL [n] | /ALL | /ERASE\n      RECALL with a number reprints history line n; /ALL lists\n      every command in the recall buffer; /ERASE clears it.\n"
        case matches(t, "MAIL"):
            return "\n  MAIL\n      Open the personal mail utility. Reports an empty inbox\n      (%MAIL-W-NOMORE) and exits.\n"
        case matches(t, "PHONE"):
            return "\n  PHONE\n      Real-time chat utility. Returns %PHONE-W-NOTAVAIL on this\n      installation.\n"
        case matches(t, "FINGER", min: 3):
            return "\n  FINGER [user]\n      Show interactive sessions on this node and any DECnet peers,\n      or details of a single user.\n"
        case matches(t, "ACCOUNTING", min: 4):
            return "\n  ACCOUNTING\n      Show the per-user accounting summary since system boot.\n"
        case matches(t, "INSTALL", min: 3):
            return "\n  INSTALL\n      List the known image table (Open / Header-resident /\n      Shared / Linkable images installed by SYSTARTUP).\n"
        case matches(t, "PRODUCT", min: 4):
            return "\n  PRODUCT\n      List installed VSI PCSI products and their kit / state /\n      release.\n"
        case matches(t, "SEARCH", min: 4):
            return "\n  SEARCH file string\n      Search the named file for a literal string.\n"
        case matches(t, "PRINT"):
            return "\n  PRINT file\n      Queue a file to SYS$PRINT.\n"
        case matches(t, "SUBMIT", min: 3):
            return "\n  SUBMIT file.COM\n      Submit a command file as a batch job to SYS$BATCH.\n"
        case matches(t, "CREATE", min: 3):
            var s = "\n  CREATE filename\n"
            s += "      Create a new sequential file. .COM files land in the on-disk\n"
            s += "      script store so EDIT and @ can find them later.\n"
            return s
        case matches(t, "CONTINUE", min: 3):
            return "\n  CONTINUE\n      Continue execution of the most recently interrupted command.\n"
        case matches(t, "COPY"):
            return "\n  COPY input-spec output-spec\n      Copy a file. (Files in this shell return %COPY-E-OPENIN -\n      -RMS-E-FNF since the namespace is read-only.)\n"
        case matches(t, "DELETE", min: 3):
            return "\n  DELETE file;version\n      Delete a file. User-created .COM files are removed from the\n      script store; everything else returns RMS file-not-found.\n"
        case matches(t, "PURGE", min: 3):
            return "\n  PURGE [filespec]\n      Delete previous versions of a file.\n"
        case matches(t, "RENAME", min: 3):
            return "\n  RENAME old-spec new-spec\n      Rename or move a file.\n"
        case matches(t, "APPEND", min: 3):
            return "\n  APPEND input-spec output-spec\n      Concatenate input onto the output file.\n"
        case matches(t, "EDIT"):
            var s = "\n  EDIT [/LINE] filename\n"
            s += "      Open a .COM file (or any text file in the script store) in the\n"
            s += "      EDT screen-mode editor: arrow keys navigate, printable input\n"
            s += "      inserts at the cursor, Enter splits the current line, BS / DEL\n"
            s += "      removes the character before the cursor (joining lines at the\n"
            s += "      column-zero margin). Page Up / Page Down scroll the viewport.\n"
            s += "      Ctrl/Z (or Ctrl/X) saves the buffer and exits; Ctrl/Y (or\n"
            s += "      ESC ESC) discards changes. The Ctrl/X and ESC ESC alternatives\n"
            s += "      are for telnet clients whose tty driver eats Ctrl/Z and Ctrl/Y\n"
            s += "      before they reach the server.\n"
            s += "\n"
            s += "      EDIT/LINE filename     Use the asterisk-prompt line editor\n"
            s += "                             (TYPE, INSERT, DELETE, FIND, etc.) for\n"
            s += "                             scripted edits.\n"
            return s
        case matches(t, "DIFFERENCES", min: 4):
            return "\n  DIFFERENCES file1 file2\n      Compare two files line-by-line.\n"
        case matches(t, "SPAWN"):
            return "\n  SPAWN [command]\n      Start a subprocess. Returns -DCL-E-NOSUBPROC since the\n      diagnostic shell does not have the subprocess facility.\n"
        case matches(t, "ATTACH"):
            return "\n  ATTACH process-name\n      Re-attach to a parent process. Returns -DCL-W-ATTNOPAR\n      because no parent exists.\n"
        case matches(t, "WAIT"):
            return "\n  WAIT hh:mm:ss[.cc]\n      Suspend the shell for the specified delta time.\n"
        case matches(t, "CLEAR"):
            return "\n  CLEAR\n      Clear the terminal scrollback.\n"
        case matches(t, "LOGOUT") || matches(t, "EXIT"):
            return "\n  LOGOUT [/FULL]    or    EXIT\n      End the DCL session and close the terminal window.\n      /FULL appends an accounting summary.\n"
        case matches(t, "SELFTEST", min: 4):
            return "\n  SELFTEST\n      Drive every documented verb once and print a per-verb\n      pass/fail line. If the shell stays up afterwards, every\n      verb dispatches without panicking.\n"

        case matches(t, "GOTO"):
            return "\n  GOTO label\n      Inside a .COM file, branch to the line `$label:`.\n"
        case matches(t, "IF"):
            var s = "\n  IF expression THEN command\n"
            s += "  IF expression THEN command ELSE command\n"
            s += "      Test a comparison and run either branch. Operators:\n"
            s += "        .EQ. .NE. .LT. .LE. .GT. .GE.     (integer)\n"
            s += "        .EQS. .NES.                        (string)\n"
            s += "        .AND. .OR. .NOT.                  (boolean)\n"
            return s
        case matches(t, "@COMMAND") || matches(t, "@"):
            var s = "\n  @file[.COM] [arg ...]\n"
            s += "      Execute a DCL command procedure. The file is loaded from\n"
            s += "      the script store; positional arguments become symbols\n"
            s += "      P1..P8.  Use EDIT to author one, then `@FILE` to run it.\n"
            return s
        case matches(t, "SCRIPTING"):
            var s = "\n  DCL scripting overview\n"
            s += "  ---- --------- --------\n"
            s += "  Each line of a .COM file begins with \"$\" (or \"$!\" for a\n"
            s += "  comment).  Supported features:\n\n"
            s += "    Labels:        $LABEL:    or    $ LABEL:\n"
            s += "    Jumps:         GOTO label, GOSUB label, RETURN, EXIT [code]\n"
            s += "    Assignments:   $ NAME = \"text\"      ! local symbol\n"
            s += "                   $ COUNT = COUNT + 1  ! integer arithmetic\n"
            s += "    Conditionals:  $ IF expr THEN cmd [ELSE cmd]\n"
            s += "    Substitution:  WRITE SYS$OUTPUT \"Hello ''USER'\"\n"
            s += "                   ('NAME' substitutes outside quotes,\n"
            s += "                    ''NAME' substitutes inside double quotes.)\n"
            s += "    Lexicals:      F$LENGTH F$EXTRACT F$LOCATE F$INTEGER\n"
            s += "                   F$STRING  F$EDIT    F$TIME   F$USER\n"
            s += "                   F$MODE    F$ENVIRONMENT       F$SEARCH\n"
            s += "    Invocation:    @filename    or    @SYS$LOGIN:STARTUP\n"
            s += "\n"
            s += "  A sample HELLO.COM and DEMO.COM are seeded into the script\n"
            s += "  store on first launch -- try `TYPE HELLO.COM` and `@HELLO`.\n"
            s += "  For a guided walkthrough, type:   HELP TUTORIAL\n"
            return s

        case matches(t, "TUTORIAL", min: 4):
            return scriptingTutorial()

        default:
            return "\n  Sorry, no further help is available for \(t).\n"
        }
    }

    /// Step-by-step DCL scripting walkthrough. Printed by HELP TUTORIAL.
    /// Long-form intentionally: the goal is for an operator who knows DCL
    /// commands at the prompt to walk away able to write a useful .COM
    /// file from scratch.
    func scriptingTutorial() -> String {
        var s = ""
        s += "\n"
        s += "  ============================================================\n"
        s += "     DCL Command-Procedure Tutorial -- \(osTitle) \(osVersion)\n"
        s += "  ============================================================\n"
        s += "\n"
        s += "  This tutorial walks you through writing and running a DCL\n"
        s += "  command procedure (a .COM file) on this node. Every example\n"
        s += "  in this guide will run on the live shell -- copy it into a\n"
        s += "  file with EDIT and execute it with @FILE.\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  1.  WHAT IS A COMMAND PROCEDURE?\n"
        s += "  ------------------------------------------------------------\n"
        s += "  A command procedure is just a text file containing the lines\n"
        s += "  you would otherwise type at the \"$\" prompt.  Every command\n"
        s += "  line begins with a \"$\" character so that DCL knows it is a\n"
        s += "  command rather than data, e.g.:\n"
        s += "\n"
        s += "      $ WRITE SYS$OUTPUT \"Hello, world.\"\n"
        s += "      $ EXIT\n"
        s += "\n"
        s += "  Lines starting with \"$!\" (or \"$ !\") are comments.  Blank\n"
        s += "  lines and lines without a leading \"$\" are treated as data and\n"
        s += "  echoed to SYS$OUTPUT.\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  2.  CREATING AND EDITING A PROCEDURE\n"
        s += "  ------------------------------------------------------------\n"
        s += "  Use EDIT to open the in-shell EDT editor on the file you want\n"
        s += "  to author:\n"
        s += "\n"
        s += "      $ EDIT GREET.COM\n"
        s += "      *INSERT\n"
        s += "      $ WRITE SYS$OUTPUT \"Hello, ''F$USER()'\"\n"
        s += "      $ EXIT\n"
        s += "      .\n"
        s += "      *EXIT\n"
        s += "\n"
        s += "  Inside the editor, INSERT enters text-input mode; type lines\n"
        s += "  until you hit a line containing just \".\" which exits the\n"
        s += "  input mode.  EXIT then writes the buffer back to disk and\n"
        s += "  returns you to the DCL prompt.  Type HELP at the * prompt for\n"
        s += "  the complete editor command set.\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  3.  RUNNING A PROCEDURE\n"
        s += "  ------------------------------------------------------------\n"
        s += "  Invoke a procedure with \"@\" followed by its name. The .COM\n"
        s += "  extension is implied:\n"
        s += "\n"
        s += "      $ @GREET\n"
        s += "      Hello, OPERATOR\n"
        s += "\n"
        s += "  You may pass up to eight positional arguments. Inside the\n"
        s += "  procedure they appear as the symbols P1, P2, ... P8:\n"
        s += "\n"
        s += "      $ ! greet.com\n"
        s += "      $ WRITE SYS$OUTPUT \"Hello, ''P1' -- from ''F$USER()'\"\n"
        s += "\n"
        s += "      $ @GREET MARK\n"
        s += "      Hello, MARK -- from OPERATOR\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  4.  SYMBOLS  (THE DCL VARIABLE SYSTEM)\n"
        s += "  ------------------------------------------------------------\n"
        s += "  A symbol is created or updated with \"=\".  String values go in\n"
        s += "  double quotes; integer values are bare numerals or arithmetic\n"
        s += "  expressions involving + - * /:\n"
        s += "\n"
        s += "      $ ROOM = \"3B\"               ! string symbol\n"
        s += "      $ FLOOR = 7                  ! integer symbol\n"
        s += "      $ FLOOR = FLOOR + 1          ! integer arithmetic\n"
        s += "\n"
        s += "  To embed a symbol in a command line, surround its name with\n"
        s += "  single apostrophes ('NAME').  When the substitution must\n"
        s += "  happen inside a double-quoted literal, use the special\n"
        s += "  two-tick-open / one-tick-close form ''NAME':\n"
        s += "\n"
        s += "      $ WRITE SYS$OUTPUT \"Cab is on floor ''FLOOR'\"\n"
        s += "      Cab is on floor 8\n"
        s += "\n"
        s += "  SHOW SYMBOL lists every symbol currently defined; SHOW SYMBOL\n"
        s += "  NAME shows just one.  A handful of read-only built-in symbols\n"
        s += "  are always available:\n"
        s += "\n"
        s += "      $STATUS    Result of the previous command (%X00000001 =\n"
        s += "                 success, anything else is a condition value)\n"
        s += "      $SEVERITY  Low 3 bits of $STATUS (0=W, 1=S, 2=E, 3=I, 4=F)\n"
        s += "      $PID       This process's PID\n"
        s += "      $PROCESS   This process's name\n"
        s += "      $RESTART   TRUE if the procedure was restarted after a\n"
        s += "                 system crash (always FALSE here)\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  5.  CONDITIONALS AND BRANCHING\n"
        s += "  ------------------------------------------------------------\n"
        s += "  IF is a single-line statement.  It supports an optional ELSE\n"
        s += "  clause; the comparison operators always begin and end with\n"
        s += "  a period:\n"
        s += "\n"
        s += "      $ IF FLOOR .GT. 10 THEN GOTO PENTHOUSE\n"
        s += "      $ IF NAME .EQS. \"OPERATOR\" THEN WRITE SYS$OUTPUT \"hi\"\n"
        s += "      $ IF FLOOR .LT. 1 .OR. FLOOR .GT. 20 -\n"
        s += "      $     THEN WRITE SYS$OUTPUT \"out of range\"\n"
        s += "\n"
        s += "  Operators recognised:\n"
        s += "      .EQ. .NE. .LT. .LE. .GT. .GE.    integer comparison\n"
        s += "      .EQS. .NES.                       string comparison\n"
        s += "      .AND. .OR. .NOT.                  boolean combinators\n"
        s += "\n"
        s += "  Labels are written as the line \"$LABEL:\" (or \"$ LABEL:\").\n"
        s += "  GOTO branches unconditionally to a label, while GOSUB calls\n"
        s += "  one and RETURN comes back to the line after the GOSUB:\n"
        s += "\n"
        s += "      $LOOP:\n"
        s += "      $   IF COUNT .GT. 5 THEN GOTO DONE\n"
        s += "      $   GOSUB STEP\n"
        s += "      $   COUNT = COUNT + 1\n"
        s += "      $   GOTO LOOP\n"
        s += "      $DONE:\n"
        s += "      $ EXIT\n"
        s += "      $STEP:\n"
        s += "      $   WRITE SYS$OUTPUT \"iteration ''COUNT'\"\n"
        s += "      $   RETURN\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  6.  LEXICAL FUNCTIONS\n"
        s += "  ------------------------------------------------------------\n"
        s += "  Lexicals are functions whose name starts with F$.  They\n"
        s += "  return strings that are substituted into the command line\n"
        s += "  before it is executed.  Some that are wired up here:\n"
        s += "\n"
        s += "      F$LENGTH(s)               number of characters in s\n"
        s += "      F$EXTRACT(start,len,s)    substring at offset start\n"
        s += "      F$LOCATE(needle,hay)      offset of needle in hay\n"
        s += "      F$INTEGER(s)              parse s as a decimal integer\n"
        s += "      F$STRING(s)               coerce s to a string\n"
        s += "      F$EDIT(s,\"UPCASE|TRIM\")   case / whitespace cleanup\n"
        s += "      F$TIME()                  current date/time stamp\n"
        s += "      F$USER()                  current user name\n"
        s += "      F$PID(ctx)                this process's PID\n"
        s += "      F$MODE()                  always \"INTERACTIVE\"\n"
        s += "      F$ENVIRONMENT(\"DEFAULT\")  current SET DEFAULT spec\n"
        s += "      F$SEARCH(file)            full spec if file exists, else \"\"\n"
        s += "      F$TRNLNM(\"LOGNAME\")       translate a logical name\n"
        s += "\n"
        s += "  Example:\n"
        s += "\n"
        s += "      $ NAME = F$EDIT(\"  joe smith \",\"TRIM,UPCASE,COMPRESS\")\n"
        s += "      $ WRITE SYS$OUTPUT \"normalised name = ''NAME'\"\n"
        s += "      normalised name = JOE SMITH\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  7.  EXITING AND ERROR HANDLING\n"
        s += "  ------------------------------------------------------------\n"
        s += "  EXIT ends the current procedure.  It may take a literal\n"
        s += "  status code which is stored in $STATUS for the caller:\n"
        s += "\n"
        s += "      $ EXIT                       ! return success\n"
        s += "      $ EXIT %X10000002            ! return %SYSTEM-F-NOPRIV\n"
        s += "\n"
        s += "  At any point a procedure can branch on $STATUS to react to a\n"
        s += "  failed command:\n"
        s += "\n"
        s += "      $ CALL CAB 01 FLOOR 99\n"
        s += "      $ IF $STATUS .NES. \"%X00000001\" -\n"
        s += "      $     THEN WRITE SYS$OUTPUT \"call failed: ''$STATUS'\"\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  8.  A COMPLETE EXAMPLE -- AUTO-DISPATCH SWEEP\n"
        s += "  ------------------------------------------------------------\n"
        s += "  The procedure below sends every cab to floor 1, opens its\n"
        s += "  doors, waits 3 seconds, closes them, and prints a summary\n"
        s += "  line.  Save it as SWEEP.COM with EDIT, then run it with\n"
        s += "  @SWEEP:\n"
        s += "\n"
        s += "      $ ! SWEEP.COM -- return every cab to the ground floor\n"
        s += "      $ N = 1\n"
        s += "      $LOOP:\n"
        s += "      $   IF N .GT. 6 THEN GOTO DONE\n"
        s += "      $   ID = F$EDIT(F$STRING(N),\"TRIM\")\n"
        s += "      $   CALL CAB 'ID' FLOOR 1\n"
        s += "      $   WAIT 00:00:03\n"
        s += "      $   OPEN CAB 'ID'\n"
        s += "      $   WAIT 00:00:03\n"
        s += "      $   CLOSE CAB 'ID'\n"
        s += "      $   N = N + 1\n"
        s += "      $   GOTO LOOP\n"
        s += "      $DONE:\n"
        s += "      $ WRITE SYS$OUTPUT \"Sweep complete at ''F$TIME()'\"\n"
        s += "      $ EXIT\n"
        s += "\n"
        s += "  ------------------------------------------------------------\n"
        s += "  9.  WHERE PROCEDURES LIVE\n"
        s += "  ------------------------------------------------------------\n"
        s += "  Files you write with EDIT live in this node's local script\n"
        s += "  store.  DIRECTORY lists them, TYPE prints them, DELETE\n"
        s += "  removes them.  The seeded examples STARTUP.COM, HELLO.COM\n"
        s += "  and DEMO.COM are good starting points for your own\n"
        s += "  procedures.\n"
        s += "\n"
        s += "  See also:\n"
        s += "    HELP SCRIPTING        quick reference card\n"
        s += "    HELP EDIT             EDT editor command summary\n"
        s += "    HELP IF, HELP GOTO    individual statement help\n"
        s += "    HELP @COMMAND         the @ verb (procedure invocation)\n"
        s += "\n"
        return s
    }

    /// SELFTEST -- drives every documented DCL verb once and prints a
    /// one-line pass / fail summary per command. A clean run means every
    /// verb dispatches and returns without panicking.
    func selfTest() async -> String {
        let verbs: [String] = [
            "SHOW PROCESS", "SHOW PROCESS/ALL",
            "SHOW SYSTEM", "SHOW USERS", "SHOW DEVICES", "SHOW MEMORY",
            "SHOW TIME", "SHOW NETWORK", "SHOW QUEUE", "SHOW ALARMS",
            "SHOW LOGICAL", "SHOW LOGICAL/PROCESS",
            "SHOW SYMBOL", "SHOW SYMBOL $STATUS", "SHOW SYMBOL $SEVERITY",
            "SHOW ERROR", "SHOW STATUS", "SHOW LICENSE",
            "SHOW CPU", "SHOW DEFAULT", "SHOW QUOTA",
            "SHOW PROTECTION", "SHOW TERMINAL", "SHOW WORKING_SET",
            "SHOW VERSION", "SHOW RMS_DEFAULT", "SHOW INTRUSION",
            "SHOW CLUSTER", "SHOW CONNECTIONS", "SHOW AUDIT",
            "SET DEFAULT [-]", "SET TERMINAL/WIDTH=80",
            "SET PROMPT=\"DCL$ \"", "SET ON", "SET NOON",
            "SET PROCESS",
            "DIRECTORY", "DIRECTORY/SIZE/DATE",
            "TYPE STARTUP.COM", "TYPE EVENTLOG.LOG", "TYPE PEERS.DAT",
            "TYPE NOSUCHFILE.TXT",
            "WRITE SYS$OUTPUT \"selftest\"",
            "ASSIGN DKA0: TEST_DISK", "DEASSIGN TEST_DISK",
            "DEFINE TEST_LOG \"value\"", "DEASSIGN TEST_LOG",
            "MAIL", "PHONE", "FINGER", "FINGER OPERATOR",
            "RECALL", "RECALL/ALL", "RECALL 1",
            "SPAWN", "ATTACH", "WAIT 00:00:01",
            "ACCOUNTING", "INSTALL", "PRODUCT",
            "SEARCH FILE.TXT \"foo\"", "PRINT REPORT.LIS",
            "SUBMIT JOB.COM",
            "CREATE NEWFILE.TXT", "CONTINUE",
            "COPY A.TXT B.TXT", "DELETE OLD.TXT", "PURGE TMP.TMP",
            "RENAME A.TXT B.TXT", "APPEND A.TXT B.TXT",
            "EDIT FILE.TXT", "DIFFERENCES A.TXT B.TXT",
            "RUN PROG.EXE", "RUN BRAKE_TEST", "RUN DOOR_TEST",
            "RUN WEIGHT_CAL", "RUN HALL_LAMP_TEST",
            "ANALYZE/ERROR_LOG", "ANALYZE/AUDIT", "ANALYZE/IMAGE",
            "INITIALIZE DKA0:",
            "MOUNT DKA0:", "MOUNT MUA0: ELEV_BACKUP",
            "DISMOUNT MUA0:",
            "BACKUP CAB$DATA: MUA0:ELEV.BCK",
            "PATCH FILE", "DEPOSIT 100",
            "EXAMINE 1000", "EXAMINE ^X100",
            "ALLOCATE MUA0:", "ALLOCATE TT0:",
            "DEALLOCATE MUA0:", "DEALLOCATE/ALL",
            "REPLY \"go ahead\"", "REQUEST \"need maintenance\"",
            "ACKNOWLEDGE ALARM ALL",
            "@STARTUP",
            "HELP", "HELP SHOW", "HELP SET", "HELP MONITOR",
            "HELP ACKNOWLEDGE", "HELP CALL", "HELP ELEVATOR", "HELP SCRIPTING",
            "HELP TUTORIAL",
        ]

        var passed = 0
        var lines: [String] = []
        lines.append("\nSELFTEST -- driving every documented verb (LOGOUT/EXIT/CLEAR excluded)\n")
        dryRun = true
        defer { dryRun = false }
        for v in verbs {
            let body = await execute(v)
            let chars = body.count
            let badFmt = body.contains("(null)") || body.contains("0x") && body.contains("Optional")
            let status: String
            if chars == 0 {
                status = "ok (no output)"
            } else if badFmt {
                status = "BAD-FMT"
            } else {
                status = "ok"
            }
            if status.hasPrefix("ok") { passed += 1 }
            let label = v.padding(toLength: 38, withPad: " ", startingAt: 0)
            lines.append(String(format: "  %@  %@  (%d chars)", label, status.padding(toLength: 14, withPad: " ", startingAt: 0), chars))
        }
        lines.append("")
        lines.append("  \(passed)/\(verbs.count) verbs returned cleanly.")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
