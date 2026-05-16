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
        add("status.alarms.summary","%d ACTIVE / %d UNACK",                "%d ACTIVES / %d NON ACQ.")

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

        add("hint.line",            "F1/?=HELP  TAB=NEXT CAB  L=LANG  D=DCL  A=AUTO/MAN  Q=QUIT",
                                    "F1/?=AIDE  TAB=CAB SUIV  L=LANGUE  D=DCL  A=AUTO/MAN  Q=QUITTER")
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
        add("help.k.esc",           "Close this overlay",                  "Fermer cette aide")
        add("help.dismiss",         "PRESS  ESC  TO DISMISS",              "APPUYEZ SUR ESC POUR FERMER")
        add("help.focus.hint",      "FOCUSED CAB",                         "CABINE FOCALISÉE")

        add("hud.cabs",             "CABS ONLINE",                         "CABINES ACTIVES")
        add("hud.floors",           "FLOORS",                              "ÉTAGES")

        add("misc.unknown",         "UNKNOWN",                             "INCONNU")
        add("misc.none",            "NONE",                                "AUCUN")
        add("misc.empty",           "(empty)",                             "(vide)")

        add("alarm.panel.title",    "SCADA ALARMS - POINT OF FAILURE",     "ALARMES SCADA - POINT DE DÉFAILLANCE")
        add("alarm.active",         "ACTIVE",                              "ACTIVES")
        add("alarm.unack",          "UNACK",                               "NON ACQ.")
        add("alarm.ack",            "ACK",                                 "ACQ.")
        add("alarm.ack.all",        "ACK ALL",                             "TOUT ACQ.")
        add("alarm.clear.ack",      "CLEAR ACK",                           "EFF. ACQ.")
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
        add("dcl.alarm.title",      "Elevator SCADA alarm log at %@",       "Journal des alarmes SCADA ascenseur à %@")
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
