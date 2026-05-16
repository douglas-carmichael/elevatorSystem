import Foundation

enum Strings {
    static let table: [String: [Lang: String]] = buildTable()

    private static func buildTable() -> [String: [Lang: String]] {
        var t: [String: [Lang: String]] = [:]
        func add(_ key: String, _ en: String, _ fr: String) {
            t[key] = [.en: en, .fr: fr]
        }

        add("window.control",       "Group Dispatcher",                    "Group Dispatcher")
        add("window.scene",         "Hoistway Synoptic",                   "Synoptique de gaine")
        add("window.dcl",           "DCL Terminal",                        "Terminal DCL")
        add("window.dynamics",      "Dynamics",                            "Dynamiques")

        add("credits.title",        "CREDITS",                             "CRÉDITS")
        add("credits.dismiss",      "Click or press ESC to close",         "Cliquez ou appuyez ESC pour fermer")
        add("credits.role.original","ORIGINAL CONCEPT & DESIGN",           "CONCEPT & DESIGN ORIGINAL")
        add("credits.role.macos",   "macOS / SwiftUI PORT",                "PORTAGE macOS / SwiftUI")

        add("banner.title",         "GROUP DISPATCHER",                    "RÉGULATEUR DE GROUPE")
        add("banner.subtitle",      "VSI OpenVMS V9.2-3   TERMINAL VT320", "VSI OpenVMS V9.2-3   TERMINAL VT320")
        add("banner.copyright",     "(C) 2026  LPD — LEVAGE & PORTES DAUPHINÉ",  "(C) 2026  LPD — LEVAGE & PORTES DAUPHINÉ")

        // The OpenVMS login banner stays English regardless of app language --
        // real VMS shipped English-only system messages, and only the LPD
        // layered-product splash below would be localised by a French vendor.
        add("dcl.banner.welcome",       "Welcome to %@ (TM) Operating System, Version %@",
                                        "Welcome to %@ (TM) Operating System, Version %@")
        add("dcl.banner.onnode",        "on node %@",                          "on node %@")
        add("dcl.banner.lastinter",     "Last interactive login on %@",        "Last interactive login on %@")
        add("dcl.banner.lastnon",       "Last non-interactive login on %@",    "Last non-interactive login on %@")
        add("dcl.banner.shelltag",      "%@ -- DIAGNOSTIC SHELL",              "%@ -- DIAGNOSTIC SHELL")
        add("dcl.banner.help",          "Type HELP for a list of available commands.",
                                        "Type HELP for a list of available commands.")

        add("status.peers",         "PEERS",                               "PAIRS")
        add("status.peers.none",    "NONE — AUTO MODE",                    "AUCUN — MODE AUTO")
        add("status.peers.node",    "NODE",                                "NŒUD")
        add("status.peers.nodes",   "NODES",                               "NŒUDS")
        add("status.discovering",   "SCANNING NETWORK...",                 "ANALYSE DU RÉSEAU...")
        add("status.elevators",     "CABS",                                "CABINES")
        add("status.telnet",        "TELNET",                              "TELNET")
        add("status.telnet.none",   "NONE",                                "AUCUNE")
        add("status.telnet.one",    "1 SESSION",                           "1 SESSION")
        add("status.telnet.many",   "%d SESSIONS",                         "%d SESSIONS")
        add("status.modbus",        "MODBUS",                              "MODBUS")
        add("status.modbus.none",   "NONE",                                "AUCUN")
        add("status.modbus.one",    "1 CLIENT",                            "1 CLIENT")
        add("status.modbus.many",   "%d CLIENTS",                          "%d CLIENTS")
        add("status.mode",          "MODE",                                "MODE")
        add("status.mode.normal",   "NORMAL",                              "NORMAL")
        add("status.mode.fire",     "FIRE PHASE I",                        "INCENDIE PHASE I")
        add("status.mode.epo",      "EMERGENCY POWER",                     "ALIM. SECOURS")
        add("status.you",           "NODE",                                "NŒUD")
        add("status.ready",         "READY",                               "PRÊT")
        add("status.alarms",        "ALARMS",                              "ALARMES")
        add("status.alarms.normal", "NORMAL",                              "NORMAL")
        add("status.alarms.summary","%d ACT / %d UNACK",                   "%d ACT / %d N.ACQ")
        // Loanword in both languages -- consistent with TELNET / MODBUS
        // / MODE above. "RÉGULATION" (10 chars) was wider than its
        // column slot and pushed onto a second row at typical window
        // widths; modern French industrial-controls operators read
        // "DISPATCH" without trouble.
        add("status.dispatch",      "DISPATCH",                            "DISPATCH")
        // Shortened so the status-strip column doesn't wrap the value
        // onto a second line at typical window widths. COLL and DEST
        // are the standard industrial-controls abbreviations -- the
        // long forms still appear in HELP CALL and SHOW DISPATCH.
        add("status.dispatch.coll", "COLL",                                "COLL")
        add("status.dispatch.dest", "DEST",                                "DEST")

        add("elev.cab",             "CAB",                                 "CABINE")
        add("elev.floor",           "FLOOR",                               "ÉTAGE")
        add("elev.direction",       "DIR",                                 "DIR")
        add("elev.doors",           "DOORS",                               "PORTES")
        add("elev.queue",           "QUEUE",                               "FILE")
        add("elev.owner",           "OWNER",                               "PROPR")
        add("elev.profile",         "TYPE",                                "TYPE")
        add("elev.profile.pax",     "PAX",                                 "PASS.")
        add("elev.profile.freight", "FRT",                                 "FRET")
        add("elev.aitag",           "AUTO",                                "AUTO")
        add("elev.localtag",        "LOCAL",                               "LOCAL")
        add("elev.remotetag",       "REMOTE",                              "DIST.")
        add("elev.remoteautotag",   "REMOTE/AUTO",                         "DIST./AUTO")

        add("dir.up",               "UP",                                  "MONTE")
        add("dir.down",             "DOWN",                                "DESC")
        add("dir.idle",             "----",                                "----")

        add("door.closed",          "CLOSED",                              "FERMÉES")
        add("door.opening",         "OPENING",                             "OUVERT.")
        add("door.open",            "OPEN",                                "OUVERTES")
        add("door.closing",         "CLOSING",                             "FERMET.")

        add("btn.call",             "CALL FLOOR",                          "APPEL ÉTAGE")
        add("btn.door.open",        "[ < > ]",                             "[ < > ]")
        add("btn.door.close",       "[ > < ]",                             "[ > < ]")
        add("btn.hold",             "HOLD",                                "MAINT")
        add("btn.close",            "CLOSE",                               "FERMER")
        add("btn.mode.auto",        "AUTO",                                "AUTO")
        add("btn.mode.manual",      "MANUAL",                              "MANUEL")
        add("btn.mode.label",       "MODE",                                "MODE")
        add("btn.profile.label",    "TYPE",                                "TYPE")
        add("btn.profile.pax",      "PAX",                                 "PASS.")
        add("btn.profile.freight",  "FRT",                                 "FRET")

        add("hint.line",            "F1/?=HELP  TAB=CAB  L=LANG  D=DCL  M=MODBUS  A=AUTO/MAN  Q=QUIT",
                                    "F1/?=AIDE  TAB=CAB  L=LANGUE  D=DCL  M=MODBUS  A=AUTO/MAN  Q=QUITTER")
        add("hint.lang",            "LANG",                                "LANGUE")

        add("help.title",           "KEYBOARD COMMANDS",                   "RACCOURCIS CLAVIER")
        add("help.k.help",          "Show / hide this overlay",            "Afficher / masquer cette aide")
        add("help.k.tab",           "Cycle focused cab",                   "Cabine suivante")
        add("help.k.lang",          "Toggle EN / FR",                      "Basculer EN / FR")
        add("help.k.quit",          "Quit the application",                "Quitter l'application")
        add("help.k.floors",        "Call focused cab to floor",           "Appeler la cabine focalisée à l'étage")
        add("help.k.doors",         "Open / close doors on focused cab",   "Ouvrir / fermer les portes")
        add("help.k.dcl",           "Open DCL diagnostic terminal",        "Ouvrir le terminal de diagnostic DCL")
        add("help.k.mode",          "Toggle AUTO / MANUAL on focused cab", "Basculer AUTO / MANUEL sur la cabine focalisée")
        add("help.k.modbus",        "Show / hide Modbus register map",     "Afficher / masquer le plan des registres Modbus")
        add("modbus.legend.title",  "MODBUS REGISTER MAP",                 "PLAN DES REGISTRES MODBUS")
        add("modbus.legend.endpoint","Endpoint:  127.0.0.1:5020   Unit ID 1   -- 8 cabs supported",
                                     "Point d'accès :  127.0.0.1:5020   Unit ID 1   -- 8 cabines")
        add("modbus.legend.ir",     "INPUT REGISTERS  (FC 04, read-only)",
                                    "REGISTRES D'ENTRÉE  (FC 04, lecture seule)")
        add("modbus.legend.hr",     "HOLDING REGISTERS  (FC 03 read, FC 06 write)",
                                    "REGISTRES DE MAINTIEN  (FC 03 lecture, FC 06 écriture)")
        add("modbus.legend.coil",   "COILS  (FC 01 read, FC 05 write)",
                                    "BOBINES  (FC 01 lecture, FC 05 écriture)")
        add("modbus.legend.di",     "DISCRETE INPUTS  (FC 02, read-only)",
                                    "ENTRÉES TOR  (FC 02, lecture seule)")
        add("modbus.reg.position",   "position × 10",
                                     "position × 10")
        add("modbus.reg.direction",  "direction (0=idle 1=up 2=dn)",
                                     "direction (0=repos 1=mte 2=dsc)")
        add("modbus.reg.doorstate",  "door state (0=closed..3=closing)",
                                     "état portes (0=fermée..3=fermeture)")
        add("modbus.reg.queue",      "queue depth",
                                     "profondeur file")
        add("modbus.reg.doorprog",   "door progress %",
                                     "progression portes %")
        add("modbus.reg.velocity",   "velocity × 100 (signed Int16)",
                                     "vitesse × 100 (Int16 signé)")
        add("modbus.reg.cabcount",   "cab count   /  101 peer count",
                                     "nb cabines   /  101 nb pairs")
        add("modbus.reg.bldgflrs",   "building floors",
                                     "étages bâtiment")
        add("modbus.reg.telnetmb",   "telnet sessions  /  104 modbus clients",
                                     "sessions telnet  /  104 clients modbus")
        add("modbus.reg.bldgmode",   "building mode  0=norm 1=fire 2=epo",
                                     "mode bâtiment  0=norm 1=feu 2=arr")
        add("modbus.reg.recallflr",  "recall floor",
                                     "étage de rappel")
        add("modbus.reg.alarms",     "active alarms  /  108 highest severity",
                                     "alarmes actives  /  108 sévérité max")
        add("modbus.reg.dispatch",   "dispatch  0=collective 1=destination",
                                     "régulation  0=collective 1=destination")
        add("modbus.reg.profile",    "profile  0=PAX  1=FRT",
                                     "profil  0=PAX  1=FRT")
        add("modbus.reg.cabmode",    "mode     0=MAN  1=AUTO",
                                     "mode     0=MAN  1=AUTO")
        add("modbus.reg.target",     "target floor -- write to CALL",
                                     "étage cible -- écrire pour APPELER")
        add("modbus.reg.dooropen",   "doors OPEN command (pulse 1)",
                                     "commande OUVRIR portes (impulsion 1)")
        add("modbus.reg.doorclose",  "doors CLOSE command",
                                     "commande FERMER portes")
        add("modbus.reg.stop",       "STOP / cancel queue",
                                     "ARRÊT / annuler file")
        add("modbus.reg.cablocal",   "cab is locally owned",
                                     "cabine locale")
        add("modbus.reg.cabmoving",  "cab is moving",
                                     "cabine en mouvement")
        add("modbus.reg.dooropened", "doors are open",
                                     "portes ouvertes")
        add("modbus.reg.brake",      "holding brake engaged",
                                     "frein de stationnement serré")
        add("modbus.reg.obstructed", "door light-curtain obstructed",
                                     "cellule porte obstruée")
        add("modbus.reg.hallcalls",  "active hall-call count",
                                     "nb appels palier actifs")
        add("modbus.reg.load",       "platform load (kg)",
                                     "charge plateau (kg)")
        add("modbus.reg.overload",   "cab over 110% rated load",
                                     "cabine en surcharge (>110%)")
        add("help.k.esc",           "Close this overlay",                  "Fermer cette aide")
        add("help.dismiss",         "PRESS  ESC  TO DISMISS",              "APPUYEZ SUR ESC POUR FERMER")
        add("help.focus.hint",      "FOCUSED CAB",                         "CABINE FOCALISÉE")

        add("hud.cabs",             "CABS ONLINE",                         "CABINES ACTIVES")
        add("hud.floors",           "FLOORS",                              "ÉTAGES")
        add("scene.recenter",       "RECENTER",                            "RECENTRER")
        add("scene.isolate",        "ISOLATE",                             "ISOLER")
        add("scene.isolated.prefix","ISOLATED:",                           "ISOLÉ :")

        add("dynamics.title",       "CAB DYNAMICS MONITOR (LPD)",
                                    "MONITEUR DYNAMIQUE CABINES (LPD)")
        add("dynamics.subtitle",    "Live trapezoidal velocity profile -- sampled every 500 ms",
                                    "Profil trapézoïdal en direct -- échantillon toutes les 500 ms")
        add("dynamics.col.cab",     "CAB",                                 "CAB")
        add("dynamics.col.pos",     "POSITION",                            "POSITION")
        add("dynamics.col.vel",     "VELOCITY",                            "VITESSE")
        add("dynamics.col.acc",     "ACCEL",                               "ACCÉL.")
        add("dynamics.col.tgt",     "TARGET",                              "CIBLE")
        add("dynamics.col.state",   "STATE",                               "ÉTAT")
        add("dynamics.empty",       "(no cabs registered)",                "(aucune cabine enregistrée)")
        add("dynamics.profile.limits","PROFILE LIMITS:",                   "LIMITES PROFIL :")
        add("dynamics.refresh",     "REFRESH 500 ms   -   PRESS Y FROM CONTROL PANEL TO TOGGLE",
                                    "RAFRAÎCHI 500 ms   -   APPUYEZ Y DEPUIS LE PUPITRE")
        add("help.k.dynamics",      "Open cab dynamics monitor",           "Ouvrir le moniteur de dynamique cabines")

        add("misc.unknown",         "UNKNOWN",                             "INCONNU")
        add("misc.none",            "NONE",                                "AUCUN")
        add("misc.empty",           "(empty)",                             "(vide)")

        add("alarm.panel.title",    "SCADA ALARMS - POINT OF FAILURE",     "ALARMES SCADA - POINT DE DÉFAILLANCE")
        add("alarm.active",         "ACTIVE",                              "ACTIVES")
        add("alarm.unack",          "UNACK",                               "NON ACQ.")
        add("alarm.ack",            "ACK",                                 "ACQ.")
        add("alarm.ack.all",        "ACK ALL",                             "TOUT ACQ.")
        add("alarm.clear.ack",      "CLEAR ACK",                           "EFF. ACQ.")
        add("alarm.inject",         "INJECT",                              "INJECTER")
        add("alarm.none.active",    "NO ACTIVE ALARMS",                    "AUCUNE ALARME ACTIVE")
        add("alarm.col.id",         "ID",                                  "ID")
        add("alarm.col.sev",        "SEV",                                 "GRAV.")
        add("alarm.col.state",      "STATE",                               "ÉTAT")
        add("alarm.col.source",     "SOURCE",                              "SOURCE")
        add("alarm.col.point",      "POINT",                               "POINT")
        add("alarm.col.message",    "MESSAGE",                             "MESSAGE")
        add("alarm.status.unack",   "UNACK",                               "NON ACQ.")
        add("alarm.status.ack",     "ACK",                                 "ACQ.")
        add("alarm.status.cleared", "CLEARED",                             "EFFACÉE")
        add("alarm.sev.advisory",   "ADVISORY",                            "INFO")
        add("alarm.sev.minor",      "MINOR",                               "MINEURE")
        add("alarm.sev.major",      "MAJOR",                               "MAJEURE")
        add("alarm.sev.critical",   "CRITICAL",                            "CRITIQUE")
        add("alarm.msg.controller", "Controller watchdog missed scan",      "Chien de garde contrôleur sans cycle")
        add("alarm.msg.doorzone",   "Door zone input mismatch",             "Discordance entrée zone de porte")
        add("alarm.msg.brake",      "Brake contact failed to prove",        "Contact frein non confirmé")
        add("alarm.msg.peerlink",   "Peer network heartbeat lost",          "Battement réseau pair perdu")
        add("alarm.msg.mains",      "Mains supply failure",                 "Défaillance alimentation secteur")
        add("alarm.msg.fire",       "Phase I fire recall active",           "Rappel incendie Phase I actif")
        add("alarm.msg.epo",        "Emergency power operation active",     "Fonctionnement sur alimentation secours")
        add("alarm.msg.overspeed",  "Cab speed exceeded profile limit",     "Vitesse cabine au-dessus de la limite")
        add("alarm.msg.landingzone", "Cab stopped outside landing zone",     "Cabine arrêtée hors zone palière")
        add("alarm.msg.doorheld",   "Doors held open beyond dwell time",    "Portes ouvertes au-delà de la temporisation")
        add("alarm.msg.doorclose",  "Door close cycle exceeded limit",      "Cycle de fermeture portes trop long")
        add("alarm.msg.dispatchstall", "Queued cab failed to start",         "Cabine en file sans démarrage")
        add("alarm.msg.terminallimit","Terminal limit switch tripped",       "Fin de course terminal déclenché")
        add("alarm.msg.brakehold",  "Brake commanded while cab is moving",   "Frein commandé alors que la cabine bouge")
        add("alarm.msg.overload",   "Cab load exceeds 110% of rated capacity", "Surcharge cabine : charge > 110% nominale")
        add("alarm.msg.fullload",   "Cab at 80% load -- anti-nuisance armed",  "Cabine à 80% : anti-nuisance armée")
        add("dcl.alarm.title",      "SCADA alarm log at %@",                "Journal des alarmes SCADA à %@")
        add("dcl.alarm.header",     "  ID    Time                         Severity   State    Source     Point          Message",
                                    "  ID    Heure                        Gravité    État     Source     Point          Message")
        add("dcl.alarm.none",       "  No alarms have been logged.",        "  Aucune alarme n'a été journalisée.")
        add("dcl.alarm.ackhint",    "  Acknowledge with:  ACKNOWLEDGE ALARM <id>   or   ACKNOWLEDGE ALARM ALL",
                                    "  Acquitter avec :  ACKNOWLEDGE ALARM <id>   ou   ACKNOWLEDGE ALARM ALL")
        add("dcl.ack.nosystem",     "%ACK-W-NOSYSTEM, elevator world is not attached",
                                    "%ACK-W-NOSYSTEM, monde ascenseur non attaché")
        add("dcl.ack.missalarm",    "%ACK-W-MISSALARM, specify ACKNOWLEDGE ALARM <id> or ACKNOWLEDGE ALARM ALL",
                                    "%ACK-W-MISSALARM, spécifiez ACKNOWLEDGE ALARM <id> ou ACKNOWLEDGE ALARM ALL")
        add("dcl.ack.missid",       "%ACK-W-MISSID, missing alarm id or ALL",
                                    "%ACK-W-MISSID, identifiant d'alarme manquant ou ALL")
        add("dcl.ack.alarms.one",   "%ACK-S-ALARMS, 1 active alarm acknowledged",
                                    "%ACK-S-ALARMS, 1 alarme active acquittée")
        add("dcl.ack.alarms.many",  "%ACK-S-ALARMS, %d active alarms acknowledged",
                                    "%ACK-S-ALARMS, %d alarmes actives acquittées")
        add("dcl.ack.invalid",      "%ACK-W-IVID, invalid alarm id %@",
                                    "%ACK-W-IVID, identifiant d'alarme invalide %@")
        add("dcl.ack.alarm",        "%ACK-S-ALARM, alarm %@ acknowledged",
                                    "%ACK-S-ALARM, alarme %@ acquittée")
        add("dcl.ack.notfound",     "%ACK-W-NOTFOUND, active alarm %@ was not found",
                                    "%ACK-W-NOTFOUND, alarme active %@ introuvable")

        // LPD diagnostic test utility (layered product -- localised because
        // an LPD-branded application absolutely would be, even though the
        // OpenVMS DCL CLI itself stays English).
        add("diag.suite",           "LPD ELEVATOR DIAGNOSTIC SUITE",       "LPD DIAGNOSTIC ASCENSEUR")
        add("diag.operator",        "Operator",                            "Opérateur")
        add("diag.started",         "Started",                             "Démarré")
        add("diag.elapsed",         "Elapsed",                             "Écoulé")
        add("diag.step.of",         "Step %d of %d",                       "Étape %d sur %d")
        add("diag.complete",        "Complete -- %d/%d steps",             "Terminé -- %d/%d étapes")
        add("diag.allpass",         "ALL PASS",                            "TOUT RÉUSSI")
        add("diag.seeresults",      "see results",                         "voir résultats")
        add("diag.abort.hint",      "Press  Ctrl/Y  or  ESC ESC  to abort", "Appuyez sur Ctrl/Y ou ESC ESC pour annuler")
        add("diag.exit.hint",       "Press  Ctrl/Y  or  ESC ESC  to exit",  "Appuyez sur Ctrl/Y ou ESC ESC pour quitter")
        add("diag.col.cab",         "Cab     Test                              Reading        Status",
                                    "Cabine  Test                              Mesure         Statut")
        add("diag.col.floor",       "Floor   Test                              Reading        Status",
                                    "Étage   Test                              Mesure         Statut")
        add("diag.menu.title",      "Diagnostic Test Selection",
                                    "Sélection des Tests de Diagnostic")
        add("diag.menu.copyright",  "Copyright (c) 1985-2026 Levage & Portes Dauphiné S.A. All rights reserved.",
                                    "Copyright (c) 1985-2026 Levage & Portes Dauphiné S.A. Tous droits réservés.")
        add("diag.menu.nav",        "UP/DOWN navigate    ENTER run    Ctrl/Y or ESC ESC exit",
                                    "HAUT/BAS naviguer    ENTRÉE exécuter    Ctrl/Y ou ESC ESC quitter")

        // Status words (column 3 of every test row).
        add("diag.status.pass",     "PASS",                                "RÉUSSI")
        add("diag.status.ok",       "OK",                                  "OK")
        add("diag.status.running",  "RUNNING",                             "EN COURS")
        add("diag.status.queued",   "(queued)",                            "(en attente)")

        // Test names.
        add("diag.test.brake",      "BRAKE HOLD-FORCE TEST",               "TEST DE FORCE DE FREINAGE")
        add("diag.test.door",       "DOOR CYCLE & OBSTRUCTION TEST",       "TEST DE CYCLE DE PORTES & D'OBSTRUCTION")
        add("diag.test.weight",     "LOAD-CELL CALIBRATION",               "ÉTALONNAGE DES CAPTEURS DE CHARGE")
        add("diag.test.lamp",       "HALL-CALL LAMP TEST",                 "TEST DES LAMPES D'APPEL PALIER")

        // Login banner block listing the LPD layered product and how to launch
        // each test utility. Localised because the layered product is.
        add("login.lpd.line1",      "LPD-DIAG V1.4  --  diagnostic kit loaded",
                                    "LPD-DIAG V1.4  --  kit de diagnostic chargé")
        add("login.lpd.line2",      "Available diagnostic test utilities (RUN <name>):",
                                    "Utilitaires de diagnostic disponibles (RUN <nom>) :")
        add("login.lpd.brake",      "  RUN BRAKE_TEST       Brake hold-force test on every cab",
                                    "  RUN BRAKE_TEST       Test de force de freinage sur chaque cabine")
        add("login.lpd.door",       "  RUN DOOR_TEST        Door open/close + obstruction sensor",
                                    "  RUN DOOR_TEST        Cycle de portes + capteur d'obstruction")
        add("login.lpd.weight",     "  RUN WEIGHT_CAL       Load-cell zero / span calibration",
                                    "  RUN WEIGHT_CAL       Étalonnage zéro / gain des capteurs de charge")
        add("login.lpd.lamp",       "  RUN HALL_LAMP_TEST   Cycle every hall-call lamp UP / DOWN",
                                    "  RUN HALL_LAMP_TEST   Cycle de toutes les lampes d'appel HAUT / BAS")
        add("login.lpd.help",       "Type HELP RUN for details. Press Ctrl/Y inside a test to abort.",
                                    "Tapez HELP RUN pour les détails. Ctrl/Y dans un test pour annuler.")

        // Per-step labels (formatted with cab label or floor number).
        add("diag.step.brake.cab",  "Cab %@ -- brake hold force",          "Cabine %@ -- force de freinage")
        add("diag.step.brake.fw",   "Cross-check brake controller firmware",
                                    "Vérification du firmware contrôleur frein")
        add("diag.step.door.cycle", "Cab %@ -- doors open/close cycle",    "Cabine %@ -- ouvert./fermet. portes")
        add("diag.step.door.obst",  "Cab %@ -- obstruction sensor",        "Cabine %@ -- capteur d'obstruction")
        add("diag.step.weight.zero","Cab %@ -- load cell zero",            "Cabine %@ -- zéro capteur de charge")
        add("diag.step.weight.span","Cab %@ -- load cell span",            "Cabine %@ -- gain capteur de charge")
        add("diag.step.weight.write","Write CAB$DATA:[CALIB]CAB.DAT",      "Écriture vers CAB$DATA:[CALIB]CAB.DAT")
        add("diag.step.lamp.floor", "Floor %@ -- UP / DOWN call lamps",    "Étage %@ -- lampes d'appel HAUT / BAS")
        add("diag.step.lamp.fw",    "Verify lamp driver firmware",         "Vérification du firmware contrôleur")

        return t
    }

    static func lookup(_ key: String, lang: Lang) -> String {
        if let row = table[key], let value = row[lang] { return value }
        if let row = table[key], let fallback = row[.en] { return fallback }
        return key
    }
}
