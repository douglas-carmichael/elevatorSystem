import Foundation

// The elevator-control node's HELP library source, in OpenVMS `.HLP`
// format (see DCLHelpLibrary.swift for the reader). Written in the
// DEC/VSI documentation voice: a one-line gloss, a Format: section, then
// parameter / qualifier / example subtopics where a command has them.
//
// Substitution tokens resolved at parse time:
//   $OSTITLE$    e.g. "VSI OpenVMS"
//   $OSVERSION$  e.g. "V9.2-3"
//   $NODE$       this node's DECnet-style name
//   $USER$       the logged-in user name
//   $STOREROOT$  host path backing ELEVATOR$ROOT:

extension HelpLibrary {
    static let source = """
1 @
  Executes a command procedure. The at sign (@) is the execute-procedure
  command; DCL reads command lines from the named file as though you had
  typed them at the terminal.

  Format:

    @file-spec[.COM] [parameter[ ...]]

  Up to eight parameters may follow the file specification. Inside the
  procedure they are available as the local symbols P1 through P8. The
  default file type is COM.

  Procedures are read from this node's command-procedure store; use EDIT
  to author one and DIRECTORY to list those already present. See also
  HELP SCRIPTING and HELP TUTORIAL.

  Example:

    $ @STARTUP
    $ @GREET MARK

2 Examples
  The procedure is located in the ELEVATOR$ROOT: command store. The .COM
  file type need not be typed:

    $ @HELLO
    $ @DEMO

1 ACCOUNTING
  Displays a per-user summary of the resources consumed on this node
  since the system was booted. The elevator node keeps a lightweight
  accounting log in place of the SYS$MANAGER:ACCOUNTNG.DAT file used on a
  full VMS system.

  Format:

    ACCOUNTING

1 ACKNOWLEDGE
  Marks one active SCADA alarm, or every active alarm, as seen by the
  operator. Acknowledging an alarm records the operator response in the
  alarm history without clearing the underlying condition; a
  process-driven alarm clears only when its cause is removed, and a
  latched fault clears only at the panel.

  Format:

    ACKNOWLEDGE ALARM {alarm-id | ALL}

  The complete alarm history, with acknowledgement state, is shown by
  SHOW ALARMS.

2 Parameters
  alarm-id

    The sequence number of a single active alarm, as listed by
    SHOW ALARMS.

  ALL

    Acknowledges every alarm currently active.

1 ALLOCATE
  Reserves a device for the exclusive use of your process. A user-class
  device (a scratch disk, a tape drive, or a terminal line) may be
  allocated; system volumes are refused.

  Format:

    ALLOCATE device-name[:]

  The allocation is held until you DEALLOCATE the device or log out.

1 ANALYZE
  Examines the internal structure of a file, an error log, the security
  audit journal, or a system dump. The operator account may inspect the
  error log and audit characteristics; image and crash-dump analysis are
  privileged.

  Format:

    ANALYZE/qualifier [file-spec]

  Additional information available:

  Choose a qualifier subtopic below for details.

2 /ERROR_LOG
  Reports the most recent entries from the system error log, in the
  format produced by ANALYZE/ERROR_LOG on a full VMS system: device
  errors, machine checks, and volume state changes.

  Format:

    ANALYZE/ERROR_LOG

2 /AUDIT
  Displays the security auditing characteristics currently in effect --
  the classes of event (login, breakin, file access, privilege use)
  being written to the audit journal.

  Format:

    ANALYZE/AUDIT

2 /IMAGE
  Analyzes the structure of an executable image. This function is
  privileged and returns %SYSTEM-F-NOPRIV for the operator account.

  Format:

    ANALYZE/IMAGE image-name

2 /CRASH_DUMP
  Reads and formats SYS$SYSTEM:SYSDUMP.DMP. This function is privileged
  and returns %SYSTEM-F-NOPRIV for the operator account.

  Format:

    ANALYZE/CRASH_DUMP dump-file

1 APPEND
  Adds the contents of one or more files to the end of an existing file.
  APPEND is COPY with the records concatenated onto the output file
  rather than replacing it.

  Format:

    APPEND input-file-spec[,...] output-file-spec

1 ASSIGN
  Creates a logical name and equates it to an equivalence string in the
  process logical name table. ASSIGN takes the equivalence name first;
  DEFINE takes the logical name first.

  Format:

    ASSIGN equivalence-name logical-name

  Use SHOW LOGICAL to display the resulting table entry and DEASSIGN to
  remove it.

1 ATTACH
  Transfers control of your terminal from the current process to another
  process in your job. The diagnostic shell has no parent process, so
  ATTACH returns -DCL-W-ATTNOPAR.

  Format:

    ATTACH process-name

1 BACKUP
  Saves, restores, or copies files as a BACKUP save set. The command
  prints the standard BACKUP identification banner and the
  CREATED/COPIED messages.

  Format:

    BACKUP input-specifier output-specifier

  Example:

    $ BACKUP CAB$DATA: MUA0:ELEV.BCK

1 CALL
  Registers an elevator service request. CALL is the operator-facing
  dispatch command: it can place a car call inside a named cab, a hall
  call at a landing fixture, or a destination-dispatch trip.

  Format:

    CALL CAB label FLOOR n
    CALL HALL /FLOOR=n {/UP | /DOWN}
    CALL DESTINATION /FROM=n /TO=m

  Additional information available:

  Choose a form below for details.

2 CAB
  Queues a floor call inside a named cab. The call bypasses the group
  dispatcher; the named cab serves it directly, modelling an in-cab car
  call placed by a rider who is already on board.

  Format:

    CALL CAB label FLOOR n

  Example:

    $ CALL CAB L02 FLOOR 7

2 HALL
  Models a landing-fixture button press. The request is latched as a
  world-level hall call (see LPDCP SHOW CALLS) and allocated to the
  nearest cab travelling in the requested direction; the hall lantern
  extinguishes when a car arrives.

  Format:

    CALL HALL /FLOOR=n {/UP | /DOWN}

2 DESTINATION
  Enters a destination-dispatch trip. The group dispatcher selects the
  cab with the lowest estimated time of arrival to the origin (with a
  small same-direction bias) and pre-loads its queue with the origin
  then the destination, so the rider is picked up first and dropped off
  second.

  Format:

    CALL DESTINATION /FROM=n /TO=m

  Destination dispatch requires LPDCP SET BUILDING /DISPATCH=DESTINATION
  so the auto-driver stands down and lets the allocator manage every
  trip.

1 CLEAR
  Clears the terminal screen and the scrollback buffer, then redisplays
  the DCL prompt.

  Format:

    CLEAR

1 CLOSE
  Requests the doors of a named cab to close. The door state machine
  honours the request subject to the reopen dwell and obstruction
  interlocks.

  Format:

    CLOSE CAB label

1 CONTINUE
  Resumes execution of a command or image that was interrupted by
  CTRL/Y. With nothing interrupted, CONTINUE has no effect.

  Format:

    CONTINUE

1 COPY
  Creates a new file from one or more existing files. In this shell the
  file namespace outside the command-procedure store is read-only, so a
  COPY whose input lies there returns %COPY-E-OPENIN and -RMS-E-FNF.

  Format:

    COPY input-file-spec[,...] output-file-spec

1 CREATE
  Creates a new sequential file. A file created with a .COM type is
  written to the command-procedure store, where EDIT and @ can find it
  later.

  Format:

    CREATE file-spec

1 DEALLOCATE
  Releases a device you previously reserved with ALLOCATE, returning it
  to the pool of free devices.

  Format:

    DEALLOCATE {device-name[:] | /ALL}

  DEALLOCATE/ALL releases every device your process holds.

1 DEASSIGN
  Cancels a logical name assignment made with ASSIGN or DEFINE. An
  undefined name returns %SYSTEM-F-NOLOGNAM.

  Format:

    DEASSIGN logical-name

1 DEFINE
  Creates a logical name and equates it to an equivalence string. DEFINE
  takes the logical name first; ASSIGN takes the equivalence name first.
  The two commands are otherwise identical.

  Format:

    DEFINE logical-name equivalence-name

1 DELETE
  Deletes one or more files. A user-authored .COM file is removed from
  the command-procedure store; a file elsewhere in the read-only
  namespace returns -RMS-E-FNF.

  Format:

    DELETE file-spec[;version]

1 DEPOSIT
  Replaces the contents of memory locations. This command is privileged
  and returns %SYSTEM-F-NOPRIV for the operator account. See EXAMINE for
  the read-only counterpart.

  Format:

    DEPOSIT location=data[,...]

1 DIAGNOSE
  Opens the elevator diagnostic test menu, a full-screen selector from
  which brake, door, load-cell and hall-lamp tests may be launched.
  Press CTRL/Y to leave the menu. See also HELP RUN, which launches the
  same tests by name.

  Format:

    DIAGNOSE

1 DIFFERENCES
  Compares two files record by record and reports the lines that differ.

  Format:

    DIFFERENCES file-spec-1 file-spec-2

1 DIRECTORY
  Displays a list of files, or information about a file or group of
  files, in the command-procedure store.

  Format:

    DIRECTORY [file-spec] [/SIZE] [/DATE] [/FULL]

  Additional information available:

  Choose a qualifier subtopic below for details.

2 /SIZE
  Adds the used and allocated block counts to each entry.

    DIRECTORY/SIZE

2 /DATE
  Adds the creation date and time to each entry.

    DIRECTORY/DATE

2 /FULL
  Displays the full set of file attributes for each entry.

    DIRECTORY/FULL

1 DISMOUNT
  Detaches a volume that was previously mounted on a device with MOUNT.

  Format:

    DISMOUNT device-name[:]

1 EDIT
  Invokes an interactive text editor on a file in the command-procedure
  store. By default EDIT starts the EDT screen editor; EDIT/LINE starts
  the EDT line editor for scripted or line-at-a-time work.

  Format:

    EDIT [/LINE] file-spec

  Additional information available:

  Choose a subtopic below for editor details.

2 Screen_Mode
  The default EDT screen editor. Arrow keys move the cursor; printable
  characters insert at the cursor; RETURN splits the current line; and
  BACKSPACE or DELETE removes the character to the left, joining lines at
  the left margin. PAGE UP and PAGE DOWN scroll the viewport.

  CTRL/Z (or CTRL/X) writes the buffer and exits; CTRL/Y (or ESC ESC)
  discards changes and exits. The CTRL/X and ESC ESC alternatives exist
  for telnet clients whose terminal driver intercepts CTRL/Z and CTRL/Y.

2 /LINE
  Starts the EDT line editor, which prompts with an asterisk (*) and
  accepts the line-mode commands TYPE, INSERT, DELETE, FIND, SUBSTITUTE
  and EXIT. Preferred for editing a procedure from a script.

  Format:

    EDIT/LINE file-spec

1 ELEVATOR
  A short worked example of driving a single cab by hand from DCL. The
  cab-specific SET and SHOW subjects live under the LPDCP layered
  product; see HELP LPDCP for the full reference.

    $ LPDCP SET CAB L02 /MANUAL      ! disable the auto-driver for L02
    $ CALL CAB L02 FLOOR 7           ! drive it to floor 7
    $ OPEN CAB L02                   ! open the doors
    $ CLOSE CAB L02                  ! close the doors
    $ STOP CAB L02                   ! cancel any pending calls
    $ LPDCP SET CAB L02 /AUTOMATIC   ! hand control back to the dispatcher
    $ LPDCP SET CAB L02 /FREIGHT     ! designate as a freight cab
    $ LPDCP SET CAB L02 /PAX         ! designate as a passenger cab

1 EXAMINE
  Displays the contents of memory. The value at the given virtual
  address is shown as a longword.

  Format:

    EXAMINE location

  A hexadecimal address may be entered as ^X1000 or as 1000. See DEPOSIT
  for the (privileged) write counterpart.

1 EXIT
  Ends the current command procedure, or, at the interactive prompt,
  ends the DCL session. An optional status value is stored in $STATUS
  for the caller. See also LOGOUT.

  Format:

    EXIT [status-code]

1 FINGER
  Displays the interactive sessions on this node and on any DECnet peers
  discovered on the network, or detailed information about a single user.

  Format:

    FINGER [user-name]

1 GOTO
  Within a command procedure, transfers control to a labelled line. The
  target is a line of the form $label: elsewhere in the procedure.

  Format:

    GOTO label

  See HELP SCRIPTING for labels, GOSUB and RETURN.

1 HELP
  Invokes the HELP facility to display information about a command or
  topic. Typed with no topic, HELP displays introductory text and then
  prompts for a topic; typed with a topic, it displays that topic and
  prompts for a subtopic.

  Format:

    HELP [topic [subtopic[ ...]]]

  At the "Topic?" prompt, type a topic name, a question mark (?) to
  redisplay the current text, an asterisk (*) to list everything, or
  press RETURN to move up one level (and, from the top level, to exit).
  Topic names may be abbreviated. Press CTRL/Z at any time to exit HELP.

2 Instructions
  See the INSTRUCTIONS topic for detailed operating instructions.

1 HINTS
  If you do not know the exact name of the command or topic you want,
  choose one of the categories below; each lists the commands that
  belong to it. Then request help on the command by name.

    Files          APPEND COPY CREATE DELETE DIFFERENCES DIRECTORY
                   PRINT PURGE RENAME SEARCH TYPE

    Devices        ALLOCATE DEALLOCATE MOUNT DISMOUNT

    Elevators      CALL OPEN CLOSE STOP LPDCP ACKNOWLEDGE RUN DIAGNOSE

    Information     SHOW MONITOR FINGER ACCOUNTING INSTALL PRODUCT

    Procedures     @ CREATE EDIT GOTO IF SUBMIT WAIT SCRIPTING TUTORIAL

    Mail_and_Msgs  MAIL PHONE REPLY REQUEST

    Session        SET RECALL SPAWN ATTACH LOGOUT EXIT

  Any command can be given the /PAGE qualifier to display long output one
  screenful at a time -- for example  SHOW SYSTEM/PAGE  or  HELP LPDCP/PAGE.
  Press RETURN for the next page, or Q to stop. The page length follows
  SET TERMINAL/PAGE.

1 IF
  Tests a condition and, when it is true, executes the command following
  THEN. An optional ELSE clause supplies a command for the false case.

  Format:

    IF expression THEN command [ELSE command]

  The comparison operators each begin and end with a period:

      .EQ. .NE. .LT. .LE. .GT. .GE.    integer comparison
      .EQS. .NES.                       string comparison
      .AND. .OR. .NOT.                  logical combination

  See HELP SCRIPTING for the surrounding procedure language.

1 INITIALIZE
  Formats and labels a volume, destroying any data already on it. This
  command is privileged and returns %SYSTEM-F-NOPRIV for the operator
  account.

  Format:

    INITIALIZE device-name[:] volume-label

1 INSTALL
  Lists the known-image table -- the images made permanently resident by
  the system startup procedure, with their attributes (Open,
  Header-resident, Shared, Linkable).

  Format:

    INSTALL [LIST]

1 INSTRUCTIONS
  HELP displays information in levels. The top level lists commands and
  topics. When you select a topic, HELP shows its text and lists the
  subtopics available beneath it, then prompts for one.

  At any prompt you may:

    o  Type a topic or subtopic name (abbreviations are accepted). Type
       several names on one line to descend directly, for example
       SHOW PROCESS.

    o  Type an asterisk (*) to display everything at the current level,
       or a name containing an asterisk to match a group of topics.

    o  Type a question mark (?) to redisplay the text you last saw.

    o  Press RETURN to move up one level. Pressing RETURN at the
       top-level "Topic?" prompt exits HELP, as does CTRL/Z at any
       prompt.

1 LOGOUT
  Ends the interactive session and closes the terminal. /FULL appends an
  accounting summary of the session.

  Format:

    LOGOUT [/FULL]

1 LPDCP
  Invokes the LPD Elevator Control Program, the layered product that
  owns every elevator-specific SET and SHOW subject. It follows the same
  pattern as the real VMS layered-product control programs (NCP for
  DECnet, LATCP for LAT, and so on).

  Format:

    LPDCP subcommand object [parameters] [/qualifiers]

  SYS$LOGIN:LOGIN.COM defines the foreign-command aliases CAB, BLDG,
  DPATCH, CALLS, LOAD, FIRE and NORMAL, so that, for example, CAB L01
  expands to LPDCP SHOW CAB L01.

  Additional information available:

  Choose a subcommand below.

2 SHOW
  Displays elevator state.

  Format:

    LPDCP SHOW object

3 CAB
  Displays a per-cab status sheet. With no label, lists every cab.

    LPDCP SHOW CAB [label]

3 BUILDING
  Displays the building safety mode, dispatch strategy and a cab census
  summary.

    LPDCP SHOW BUILDING

3 DISPATCH
  Displays the group dispatch mode and the most recent allocations.

    LPDCP SHOW DISPATCH

3 CALLS
  Displays the latched hall calls and the per-cab car-call queues.

    LPDCP SHOW CALLS

3 LOAD
  Displays the platform load-cell reading for each cab.

    LPDCP SHOW LOAD

2 SET
  Modifies elevator state.

  Format:

    LPDCP SET object /qualifiers

3 CAB
  Sets the operating attributes of a single cab.

    LPDCP SET CAB label /MANUAL | /AUTOMATIC | /PAX | /FREIGHT
                        /PHASE2=ON|OFF | /INDEPENDENT=ON|OFF | /LOAD=kg

3 BUILDING
  Sets a building-wide safety or dispatch mode.

    LPDCP SET BUILDING /FIRE_RECALL=ON|OFF [/FLOOR=n]
                       /EPO=ON|OFF [/CAB=label]
                       /NORMAL
                       /DISPATCH=COLLECTIVE|DESTINATION

2 HELP
  Displays the detailed LPDCP command reference.

    LPDCP HELP

1 MAIL
  Invokes the $OSTITLE$ Personal Mail Utility. Typed by itself, MAIL
  opens the MAIL> subshell for reading and sending messages; a one-line
  form is also accepted for use in procedures.

  Format:

    MAIL
    MAIL {DIRECTORY | READ [n] | SEND addr "subj" "text" | DELETE n}

  The building writes in-universe status mail (OPCOM and SCADA notices)
  into the same inbox as its state changes.

  Additional information available:

  Choose a MAIL> subcommand below.

2 DIRECTORY
  Lists the messages in the current folder, marking the current message
  and any that are new.

    MAIL> DIRECTORY

2 READ
  Displays a message. With no number, reads the current message, or the
  first new message if none is current. A bare RETURN at the MAIL>
  prompt reads the next message.

    MAIL> READ [n]

2 SEND
  Composes and sends a message. You are prompted for To:, Subj: and the
  message text; end the text with CTRL/Z, or CTRL/C to abandon it.

    MAIL> SEND [addr]

2 REPLY
  Composes a reply to the current message, pre-filling the recipient and
  the subject.

    MAIL> REPLY

2 FORWARD
  Forwards the current message, pre-loading the body with the forwarded
  text so you can add a note before sending.

    MAIL> FORWARD [addr]

2 DELETE
  Deletes a message. With no number, deletes the current message;
  DELETE ALL empties the folder.

    MAIL> DELETE [n | ALL]

2 Navigation
  NEXT and BACK step through the folder; FIRST and LAST jump to its ends;
  CURRENT redisplays the current message.

    MAIL> {NEXT | BACK | FIRST | LAST | CURRENT}

2 EXIT
  Leaves MAIL and returns to the DCL prompt. QUIT is a synonym.

    MAIL> EXIT

1 MONITOR
  Displays a continuously updated, full-screen report of a class of
  system activity. The display refreshes every INTERVAL seconds (default
  3). Press CTRL/Y (or ESC ESC over telnet) to interrupt it and return
  to the DCL prompt.

  Format:

    MONITOR class [/INTERVAL=seconds]

  Additional information available:

  Choose a class below.

2 SYSTEM
  A composite display: processor mode breakdown, I/O rates and paging.

2 MODES
  The time the processor spends in each access mode.

2 PROCESSES
  The top processes by CPU time, as a bar chart.

2 IO
  I/O subsystem rates.

2 PAGE
  Page-management rates and the size of the free and modified lists.

2 STATES
  The number of processes in each scheduling state.

2 DISK
  Per-disk operation rates.

2 LOCK
  Distributed lock manager rates.

2 CLUSTER
  A per-node summary of CPU, I/O and memory across the cluster.

2 FCP
  Files-11 XQP file-primitive rates.

2 DYNAMICS
  Live cab dynamics -- position, velocity, acceleration and state. This
  is an LPD extension class.

2 ALL_CLASSES
  A concatenation of the SYSTEM, IO and STATES displays.

1 MOUNT
  Attaches a volume to a device and makes its files available. The
  volume label defaults to SCRATCH when omitted. System volumes are
  refused.

  Format:

    MOUNT device-name[:] [volume-label]

1 OPEN
  Requests the doors of a named cab to open. The door state machine
  honours the request subject to the position and interlock conditions.

  Format:

    OPEN CAB label

1 PATCH
  Modifies an image or data file in place. This command is privileged
  and returns %SYSTEM-F-NOPRIV for the operator account.

  Format:

    PATCH file-spec

1 PHONE
  Establishes a real-time conversation with another user. This utility
  is not available on this installation and returns %PHONE-W-NOTAVAIL.

  Format:

    PHONE

1 PRINT
  Queues one or more files to a print queue for printing. Files are
  queued to SYS$PRINT.

  Format:

    PRINT file-spec[,...]

1 PRODUCT
  Displays or manages software products installed with the POLYCENTER
  Software Installation utility. Listed here are the installed VSI PCSI
  products with their kit, state and release.

  Format:

    PRODUCT SHOW PRODUCT

1 PURGE
  Deletes all but the most recent version, or versions, of the specified
  files.

  Format:

    PURGE [file-spec]

1 RECALL
  Displays or re-executes commands stored in the recall buffer.

  Format:

    RECALL [n | /ALL | /ERASE]

  RECALL n reprints command n; /ALL lists every command in the buffer;
  /ERASE clears the buffer. Up-arrow and down-arrow also step through it.

1 RENAME
  Changes the name, type, or version of one or more files.

  Format:

    RENAME input-file-spec output-file-spec

1 REPLY
  Sends a message to the operator console (OPA0:). The elevator node
  queues the reply line to OPCOM.

  Format:

    REPLY "message-text"

1 REQUEST
  Sends a message to the system operator and logs a request for
  operator assistance through OPCOM.

  Format:

    REQUEST "message-text"

1 RUN
  Executes an installed image. The operator account may run the elevator
  diagnostic images; other images return %SYSTEM-F-NOPRIV.

  Format:

    RUN image-name[/NODE=node-id]

  A test runs on the local node's cabs by default. /NODE selects a
  target node: L for the local node, or a peer letter (A, B, ...). A
  test always targets exactly one node. HALL_LAMP_TEST always drives the
  local landing fixtures.

  Additional information available:

  Choose a diagnostic image below.

2 BRAKE_TEST
  Performs a brake hold-force test on every cab on the target node.

    RUN BRAKE_TEST[/NODE=id]

2 DOOR_TEST
  Cycles the doors open and closed and exercises the obstruction sensor
  on every cab on the target node.

    RUN DOOR_TEST[/NODE=id]

2 WEIGHT_CAL
  Runs the load-cell zero and span calibration on every cab on the
  target node.

    RUN WEIGHT_CAL[/NODE=id]

2 HALL_LAMP_TEST
  Cycles every hall-call lamp UP and DOWN. This test always drives the
  local node's landing fixtures.

    RUN HALL_LAMP_TEST

1 SCRIPTING
  An overview of the DCL command-procedure language. Every command line
  in a procedure begins with a dollar sign ($); a line beginning with $!
  is a comment; a line with no leading $ is data echoed to SYS$OUTPUT.

  For a step-by-step guide, type HELP TUTORIAL.

  Additional information available:

  Choose an element below.

2 Symbols
  A symbol is created or updated with the equals sign. String values are
  quoted; integer values are numerals or arithmetic expressions:

    $ ROOM = "3B"                 ! string symbol
    $ FLOOR = 7                   ! integer symbol
    $ FLOOR = FLOOR + 1           ! integer arithmetic

  SHOW SYMBOL lists the defined symbols. The read-only symbols $STATUS,
  $SEVERITY, $PID, $PROCESS and $RESTART are always available.

2 Substitution
  Enclose a symbol name in apostrophes to substitute its value into a
  command line. Inside a quoted string, use the two-apostrophe opening
  form:

    $ WRITE SYS$OUTPUT "Cab is on floor ''FLOOR'"

2 Labels
  A label is a line of the form $label:. GOTO branches to a label; GOSUB
  calls the code at a label and RETURN comes back to the line after the
  GOSUB:

    $LOOP:
    $   IF COUNT .GT. 5 THEN GOTO DONE
    $   GOSUB STEP
    $   COUNT = COUNT + 1
    $   GOTO LOOP
    $DONE:

2 Conditionals
  IF tests a condition and runs the command after THEN, with an optional
  ELSE branch. See HELP IF for the operator list.

    $ IF FLOOR .GT. 10 THEN GOTO PENTHOUSE

2 Lexical_Functions
  Lexical functions have names beginning with F$ and return a string
  substituted into the command line before it runs:

      F$LENGTH  F$EXTRACT  F$LOCATE  F$INTEGER  F$STRING
      F$EDIT    F$TIME     F$USER    F$MODE     F$ENVIRONMENT
      F$SEARCH  F$TRNLNM   F$PID

  Example:

    $ NAME = F$EDIT("  joe smith ","TRIM,UPCASE,COMPRESS")

2 Invocation
  Run a procedure with the @ command; up to eight parameters become the
  symbols P1 through P8:

    $ @GREET MARK

1 SEARCH
  Searches one or more files for the specified string and displays the
  lines that contain it.

  Format:

    SEARCH file-spec search-string

1 SELFTEST
  Drives every documented DCL verb once, in dry-run mode, and prints a
  per-verb pass or fail line. If the shell is still responsive
  afterwards, every verb dispatches without error. This is the elevator
  node's built-in command self-test.

  Format:

    SELFTEST

1 SET
  Modifies the characteristics of your process, your terminal, or the
  session environment. The cab and building SET subjects live under the
  LPDCP layered product (see HELP LPDCP).

  Format:

    SET option [value]

  Additional information available:

  Choose an option below.

2 DEFAULT
  Sets the default device and directory for file operations.

    SET DEFAULT [device:][directory]

2 TERMINAL
  Sets terminal characteristics such as display width and page length.

    SET TERMINAL /WIDTH=n /PAGE=n

2 PROMPT
  Sets the DCL prompt string.

    SET PROMPT="string"

2 PROCESS
  Sets process characteristics such as scheduling priority and name.

    SET PROCESS /PRIORITY=n /NAME=name

2 PASSWORD
  Changes the password of the current account.

    SET PASSWORD

2 ON
  Enables error checking, so that a warning or worse in a procedure
  triggers the established ON action. NOON disables the checking.

    SET {ON | NOON}

2 VERIFY
  Enables command echo, so that each line of a procedure is displayed as
  it executes. NOVERIFY disables the echo.

    SET {VERIFY | NOVERIFY}

2 STANDARD
  Chooses which lift-safety standard's terminology the interface presents:
  ASME A17.1 (North American) or EN 81 (European). AUTO, the default,
  follows the interface language -- French shows EN 81, English shows ASME.
  Affects SHOW MODBUS contact names, the safety-chain labels and the
  fire-recall line in SHOW STATUS.

    SET STANDARD {ASME | EN81 | AUTO}

1 SHELVE
  Shelves an active SCADA alarm (ISA-18.2 SHLVD): the alarm is removed from
  the primary annunciator -- the beacon, the panel list and the active
  count -- while remaining in the log so the action stays auditable. Use it
  to silence a known nuisance alarm without losing the record. UNSHELVE
  restores it. Distinct from ACKNOWLEDGE, which keeps the alarm annunciated.

  Format:

    SHELVE ALARM alarm-id

  The alarm sequence number is the one listed by SHOW ALARMS.

1 SHOW
  Displays information about the process, the system, devices, and the
  session environment. The elevator subjects (CAB, BUILDING, DISPATCH,
  CALLS, LOAD) live under the LPDCP layered product; see HELP LPDCP.

  Format:

    SHOW option

  Additional information available:

  Choose a subject below.

2 PROCESS
  Displays information about a process. /ALL displays the full set of
  process attributes.

    SHOW PROCESS [/ALL]

2 SYSTEM
  Displays the processes on the system, with their state and resource
  use.

    SHOW SYSTEM

2 USERS
  Displays the interactive users logged in to the node.

    SHOW USERS

2 DEVICES
  Displays the status of the devices on the system.

    SHOW DEVICES

2 MEMORY
  Displays the availability and use of physical memory and paging.

    SHOW MEMORY

2 MODBUS
  Displays the Modbus TCP register map (coils, discrete inputs including
  the safety chain, holding registers, input registers) so external tools
  such as mbpoll, pymodbus, OpenPLC and Node-RED can be wired to the right
  addresses. Safety-chain contact names follow the active safety standard
  (see SET STANDARD).

    SHOW MODBUS

2 TIME
  Displays the current date and time.

    SHOW TIME

2 NETWORK
  Displays the state of the network and the reachable nodes.

    SHOW NETWORK

2 QUEUE
  Displays the batch and print queues and the jobs in them.

    SHOW QUEUE

2 ALARMS
  Displays the SCADA alarm log, with each alarm's severity, source,
  point and acknowledgement state. By default only standing (active,
  unshelved) alarms are shown; /ALL lists the full journal, including
  cleared, returned-to-normal (RTN) and shelved (SHLVD) history.

    SHOW ALARMS [/ALL]

2 DIAGNOSTICS
  Displays the results of the most recent diagnostic tests.

    SHOW DIAGNOSTICS

2 LOGICAL
  Displays logical name translations. /PROCESS limits the display to the
  process logical name table.

    SHOW LOGICAL [/PROCESS] [name]

2 SYMBOL
  Displays the value of a DCL symbol, or of every symbol when no name is
  given.

    SHOW SYMBOL [name]

2 ERROR
  Displays a summary of recent device and system errors.

    SHOW ERROR

2 STATUS
  Displays the status and accumulated resource use of the current
  process.

    SHOW STATUS

2 LICENSE
  Displays the software licences registered on the node.

    SHOW LICENSE

2 CPU
  Displays the state of the processors in the system.

    SHOW CPU

2 DEFAULT
  Displays the current default device and directory.

    SHOW DEFAULT

2 QUOTA
  Displays the disk quota in effect for a user.

    SHOW QUOTA

2 PROTECTION
  Displays the default file protection applied to new files.

    SHOW PROTECTION

2 TERMINAL
  Displays the characteristics of your terminal.

    SHOW TERMINAL

2 WORKING_SET
  Displays the working-set limits and quota of the current process.

    SHOW WORKING_SET

2 VERSION
  Displays the operating-system name and version ($OSTITLE$
  $OSVERSION$).

    SHOW VERSION

2 RMS_DEFAULT
  Displays the process and system RMS default multiblock and
  multibuffer counts.

    SHOW RMS_DEFAULT

2 INTRUSION
  Displays the entries in the intrusion database (failed-login and
  break-in records).

    SHOW INTRUSION

2 CLUSTER
  Displays the members of the cluster and their connections. See also
  MONITOR CLUSTER.

    SHOW CLUSTER

2 CONNECTIONS
  Displays the logical links and their state.

    SHOW CONNECTIONS

2 AUDIT
  Displays the security-auditing characteristics in effect.

    SHOW AUDIT

1 SPAWN
  Creates a subprocess to execute a command or an interactive session.
  The diagnostic shell has no subprocess facility, so SPAWN returns
  -DCL-E-NOSUBPROC.

  Format:

    SPAWN [command]

1 STOP
  Clears the queued floor calls of a named cab, cancelling its pending
  service.

  Format:

    STOP CAB label

1 STORAGE
  Describes the on-disk storage that backs the simulated ELEVATOR$ROOT:
  volume. Files kept there round-trip between the host and the shell.

  The host directory is:

    $STOREROOT$

  File types kept there:

    *.COM         Command procedures (CREATE / EDIT / TYPE / @ /
                  DELETE / COPY / RENAME / APPEND).
    *.LOG         Batch-job logs written by SUBMIT when a procedure
                  finishes.
    MAILBOX.JSON  The persistent MAIL inbox; it re-seeds with the
                  welcome messages if deleted.

  STARTUP.COM, HELLO.COM and DEMO.COM are seeded into the directory on
  first launch. The INSTALL known-image table lives only in memory and
  re-seeds on every start.

1 SUBMIT
  Queues one or more command procedures to a batch queue for execution
  as a detached job. The prompt returns immediately; the job runs in the
  background.

  Format:

    SUBMIT file-spec[,...]

  When the job finishes, OPCOM posts a notification to this terminal,
  MAIL delivers the captured output, and a .LOG file is written beside
  the .COM (see HELP STORAGE for the host path).

1 TUTORIAL
  A step-by-step tutorial on writing and running DCL command procedures
  on this node. Every example runs on the live shell.

  Additional information available:

  Choose a lesson below, or read them in order.

2 Overview
  A command procedure is a text file containing the lines you would
  otherwise type at the "$" prompt. Every command line begins with a "$"
  so DCL treats it as a command rather than data:

    $ WRITE SYS$OUTPUT "Hello, world."
    $ EXIT

  Lines beginning with "$!" are comments. Blank lines, and lines with no
  leading "$", are treated as data and echoed to SYS$OUTPUT.

2 Editing
  Use EDIT to open the EDT editor on the file you want to author. Type
  your lines, then write the file and return to DCL. The default file
  type COM need not be typed. See HELP EDIT for the editor commands.

    $ EDIT GREET.COM

2 Running
  Invoke a procedure with "@" followed by its name. Up to eight
  positional parameters follow the name and appear inside the procedure
  as P1 through P8:

    $ @GREET
    $ @GREET MARK

2 Symbols
  A symbol is created with "=". String values are quoted; integers are
  numerals or arithmetic. Substitute a symbol into a line by enclosing
  its name in apostrophes:

    $ FLOOR = 7
    $ WRITE SYS$OUTPUT "Cab is on floor ''FLOOR'"

  See HELP SCRIPTING Symbols for the read-only $STATUS and $SEVERITY
  symbols.

2 Branching
  IF is a single-line statement with an optional ELSE. Labels are lines
  of the form $label:; GOTO branches to one, GOSUB calls one and RETURN
  comes back. See HELP IF and HELP GOTO.

    $ IF FLOOR .GT. 10 THEN GOTO PENTHOUSE

2 Lexical_Functions
  Lexical functions (names beginning with F$) return strings substituted
  into the command line before it runs -- F$TIME, F$USER, F$EDIT,
  F$EXTRACT, and others. See HELP SCRIPTING Lexical_Functions.

    $ NAME = F$EDIT("  joe smith ","TRIM,UPCASE")

2 Example
  This procedure sends every cab to floor 1, opens and closes its doors,
  and prints a summary. Save it as SWEEP.COM and run it with @SWEEP:

    $ ! SWEEP.COM -- return every cab to the ground floor
    $ N = 1
    $LOOP:
    $   IF N .GT. 6 THEN GOTO DONE
    $   ID = F$EDIT(F$STRING(N),"TRIM")
    $   CALL CAB 'ID' FLOOR 1
    $   WAIT 00:00:03
    $   OPEN CAB 'ID'
    $   WAIT 00:00:03
    $   CLOSE CAB 'ID'
    $   N = N + 1
    $   GOTO LOOP
    $DONE:
    $ WRITE SYS$OUTPUT "Sweep complete at ''F$TIME()'"
    $ EXIT

1 TYPE
  Displays the contents of one or more sequential ASCII files at the
  terminal. A user-authored .COM file is read from the command-procedure
  store; a binary file (such as PEERS.DAT) returns %TYPE-W-NOTASCII.

  Format:

    TYPE file-spec[,...]

1 UNSHELVE
  Restores a shelved SCADA alarm (see HELP SHELVE) to the primary
  annunciator. If the underlying condition is still present the alarm
  re-annunciates immediately.

  Format:

    UNSHELVE ALARM alarm-id

1 WAIT
  Suspends the procedure or the interactive session for the specified
  delta time.

  Format:

    WAIT hh:mm:ss[.cc]

1 WRITE
  Writes a line to an open file or to a logical device. WRITE
  SYS$OUTPUT echoes a literal string to the terminal; other destinations
  return a WRITERR condition in this shell.

  Format:

    WRITE logical-name expression
"""
}
