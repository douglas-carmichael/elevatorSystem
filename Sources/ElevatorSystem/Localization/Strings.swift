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

        add("dcl.banner.welcome",       "Welcome to %@ (TM) Operating System, Version %@",
                                        "Bienvenue dans %@ (TM), système d'exploitation version %@")
        add("dcl.banner.onnode",        "on node %@",                          "sur le nœud %@")
        add("dcl.banner.lastinter",     "Last interactive login on %@",        "Dernière connexion interactive : %@")
        add("dcl.banner.lastnon",       "Last non-interactive login on %@",    "Dernière connexion non-interactive : %@")
        add("dcl.banner.shelltag",      "%@ -- DIAGNOSTIC SHELL",              "%@ -- SHELL DIAGNOSTIC")
        add("dcl.banner.help",          "Type HELP for a list of available commands.",
                                        "Tapez HELP pour la liste des commandes disponibles.")

        add("status.peers",         "PEERS",                               "PAIRS")
        add("status.peers.none",    "NONE — AUTO MODE",                    "AUCUN — MODE AUTO")
        add("status.peers.node",    "NODE",                                "NŒUD")
        add("status.peers.nodes",   "NODES",                               "NŒUDS")
        add("status.discovering",   "SCANNING NETWORK...",                 "ANALYSE DU RÉSEAU...")
        add("status.elevators",     "CABS",                                "CABINES")
        add("status.you",           "NODE",                                "NŒUD")
        add("status.ready",         "READY",                               "PRÊT")

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

        // LPD diagnostic test utility (layered product -- localised because
        // an LPD-branded application absolutely would be, even though the
        // OpenVMS DCL CLI itself stays English).
        add("diag.suite",           "LPD ELEVATOR DIAGNOSTIC SUITE",       "LPD SUITE DE DIAGNOSTIC ASCENSEUR")
        add("diag.operator",        "Operator",                            "Opérateur")
        add("diag.started",         "Started",                             "Démarré")
        add("diag.elapsed",         "Elapsed",                             "Écoulé")
        add("diag.step.of",         "Step %d of %d",                       "Étape %d sur %d")
        add("diag.complete",        "Complete -- %d/%d steps",             "Terminé -- %d/%d étapes")
        add("diag.allpass",         "ALL PASS",                            "TOUT RÉUSSI")
        add("diag.seeresults",      "see results",                         "voir résultats")
        add("diag.abort.hint",      "Press  Ctrl/Y  to abort",             "Appuyez sur Ctrl/Y pour annuler")
        add("diag.exit.hint",       "Press  Ctrl/Y  to exit",              "Appuyez sur Ctrl/Y pour quitter")
        add("diag.col.cab",         "Cab     Test                              Reading        Status",
                                    "Cabine  Test                              Mesure         Statut")
        add("diag.col.floor",       "Floor   Test                              Reading        Status",
                                    "Étage   Test                              Mesure         Statut")
        add("diag.menu.title",      "Diagnostic Test Selection",
                                    "Sélection des Tests de Diagnostic")
        add("diag.menu.copyright",  "Copyright (c) 1985, 2026 LPD Systems, Inc.   All rights reserved.",
                                    "Copyright (c) 1985, 2026 LPD Systèmes, Inc.   Tous droits réservés.")
        add("diag.menu.nav",        "UP / DOWN to navigate    ENTER to run    Ctrl/Y to exit",
                                    "HAUT / BAS pour naviguer    ENTRÉE pour exécuter    Ctrl/Y pour quitter")

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
                                    "Vérification du firmware controleur frein")
        add("diag.step.door.cycle", "Cab %@ -- doors open/close cycle",    "Cabine %@ -- cycle ouvert./fermet. portes")
        add("diag.step.door.obst",  "Cab %@ -- obstruction sensor",        "Cabine %@ -- capteur d'obstruction")
        add("diag.step.weight.zero","Cab %@ -- load cell zero",            "Cabine %@ -- zéro capteur de charge")
        add("diag.step.weight.span","Cab %@ -- load cell span",            "Cabine %@ -- gain capteur de charge")
        add("diag.step.weight.write","Write CAB$DATA:[CALIB]CAB.DAT",      "Écriture vers CAB$DATA:[CALIB]CAB.DAT")
        add("diag.step.lamp.floor", "Floor %@ -- UP / DOWN call lamps",    "Étage %@ -- lampes d'appel HAUT / BAS")
        add("diag.step.lamp.fw",    "Verify lamp driver firmware",         "Vérification du firmware controleur lampes")

        return t
    }

    static func lookup(_ key: String, lang: Lang) -> String {
        if let row = table[key], let value = row[lang] { return value }
        if let row = table[key], let fallback = row[.en] { return fallback }
        return key
    }
}
