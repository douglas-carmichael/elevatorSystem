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

        add("hint.line",            "F1/?=HELP  TAB=CAB  L=LANG  D=DCL  Y=DYNAMICS  M=MODBUS  A=AUTO/MAN  Q=QUIT",
                                    "F1/?=AIDE  TAB=CAB  L=LANGUE  D=DCL  Y=DYNAMIQUE  M=MODBUS  A=AUTO/MAN  Q=QUITTER")
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
        add("modbus.legend.endpoint","Endpoint:  127.0.0.1:5020   Unit ID 1   -- 16 cab slots (local + remote)",
                                     "Point d'accès :  127.0.0.1:5020   Unit ID 1   -- 16 empl. cabine (locales + distantes)")
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
        add("modbus.reg.accel",      "acceleration × 100 (signed, floors/s²)",
                                     "accélération × 100 (signé, étages/s²)")
        add("modbus.reg.velocity",   "velocity × 100 (signed Int16)",
                                     "vitesse × 100 (Int16 signé)")
        add("modbus.reg.cabcount",   "cab count   /  1001 peer count",
                                     "nb cabines   /  1001 nb pairs")
        add("modbus.reg.bldgflrs",   "building floors",
                                     "étages bâtiment")
        add("modbus.reg.telnetmb",   "telnet sessions  /  1004 modbus clients",
                                     "sessions telnet  /  1004 clients modbus")
        add("modbus.reg.bldgmode",   "building mode  0=norm 1=fire 2=epo",
                                     "mode bâtiment  0=norm 1=feu 2=arr")
        add("modbus.reg.recallflr",  "recall floor",
                                     "étage de rappel")
        add("modbus.reg.alarms",     "active alarms  /  1008 highest severity",
                                     "alarmes actives  /  1008 sévérité max")
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
        // SHOW MODBUS -- lines specific to the terminal listing
        add("modbus.show.standard",  "Safety standard: %@",                 "Norme de sécurité : %@")
        add("modbus.show.safetychain","SAFETY CHAIN  (FC 02, 1 = contact closed / healthy)",
                                     "CHAÎNE DE SÉCURITÉ  (FC 02, 1 = contact fermé / sain)")
        add("modbus.show.unacked",   "unacknowledged alarms",               "alarmes non acquittées")
        add("modbus.show.shelved",   "shelved alarms (SHLVD)",              "alarmes masquées (SHLVD)")
        add("modbus.show.rtn",       "returned-to-normal, unacked (RTN)",   "retour à la normale, non acq. (RAN)")
        add("help.k.esc",           "Close this overlay",                  "Fermer cette aide")
        add("help.dismiss",         "PRESS  ESC  TO DISMISS",              "APPUYEZ SUR ESC POUR FERMER")
        add("help.focus.hint",      "FOCUSED CAB",                         "CABINE FOCALISÉE")

        add("hud.cabs",             "CABS ONLINE",                         "CABINES ACTIVES")
        add("hud.floors",           "FLOORS",                              "ÉTAGES")
        add("scene.recenter",       "RECENTER",                            "RECENTRER")
        add("scene.isolate",        "ISOLATE",                             "ISOLER")
        add("scene.isolated.prefix","ISOLATED:",                           "ISOLÉ :")

        add("dynamics.title",       "CAB DYNAMICS MONITOR",
                                    "MONITEUR DYNAMIQUE CABINES")
        add("dynamics.col.cab",     "CAB",                                 "CAB")
        add("dynamics.col.pos",     "POSITION",                            "POSITION")
        add("dynamics.col.vel",     "VELOCITY",                            "VITESSE")
        add("dynamics.col.acc",     "ACCEL",                               "ACCÉL.")
        add("dynamics.col.tgt",     "TARGET",                              "CIBLE")
        add("dynamics.col.state",   "STATE",                               "ÉTAT")
        add("dynamics.empty",       "(no cabs registered)",                "(aucune cabine enregistrée)")
        add("dynamics.profile.limits","PROFILE LIMITS:",                   "LIMITES PROFIL :")
        add("dynamics.refresh",     "REFRESH 500 ms",                      "RAFRAÎCHI 500 ms")
        add("dynamics.trace.title", "VELOCITY TRACE  60 s WINDOW",
                                    "TRACÉ VITESSE  FENÊTRE 60 s")
        add("dynamics.trace.empty", "(awaiting samples)",                  "(échantillons en attente)")
        add("dynamics.trace.axis",  "+limit / 0 / -limit (fl/s)",          "+limite / 0 / -limite (fl/s)")
        add("dynamics.state.gloss", "",
                                    "LÉGENDE :  IDLE=REPOS  ACCEL=ACCÉL.  CRUISE=CROISIÈRE  DECEL=DÉCÉL.  STOPPING=ARRÊT  BRAKE=FREIN  DOORS=PORTES  PARKED=À QUAI  OBSTR=OBSTRUCTION  PHASE-II=PHASE II  INDEP=INDÉP.")
        add("dynamics.scope.label", "SCOPE:",                              "PORTÉE :")
        add("dynamics.scope.all",   "ALL",                                 "TOUTES")
        add("dynamics.scope.local", "LOCAL",                               "LOCALES")
        add("dynamics.scope.remote","REMOTE",                              "DISTANTES")
        add("dynamics.select.label","CABS:",                               "CABINES :")
        add("dynamics.select.all",  "ALL",                                 "TOUTES")
        add("dynamics.select.none", "NONE",                                "AUCUNE")
        add("dynamics.select.empty","(no cabs in scope)",                  "(aucune cabine dans la portée)")
        add("help.k.dynamics",      "Open cab dynamics monitor",           "Ouvrir le moniteur de dynamique cabines")

        add("misc.unknown",         "UNKNOWN",                             "INCONNU")
        add("misc.none",            "NONE",                                "AUCUN")
        add("misc.empty",           "(empty)",                             "(vide)")

        add("alarm.panel.title",    "SCADA ALARMS - POINT OF FAILURE",     "ALARMES SCADA - POINT DE DÉFAILLANCE")
        add("alarm.active",         "ACTIVE",                              "ACTIVES")
        add("alarm.unack",          "UNACK",                               "NON ACQ.")
        add("alarm.ack",            "ACK",                                 "ACQ.")
        add("alarm.ack.all",        "ACK ALL",                             "TOUT ACQ.")
        add("alarm.clear.all",      "CLEAR ALL",                           "TOUT EFF.")
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
        add("alarm.status.rtn",     "RTN",                                 "RAN")
        add("alarm.status.shlvd",   "SHLVD",                               "MASQ.")
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
        add("dcl.alarm.ackhint",    "  Acknowledge:  ACKNOWLEDGE ALARM <id>|ALL    Shelve:  SHELVE ALARM <id>   (UNSHELVE to restore)",
                                    "  Acquitter :  ACKNOWLEDGE ALARM <id>|ALL    Masquer :  SHELVE ALARM <id>   (UNSHELVE pour rétablir)")
        // SHELVE / UNSHELVE (ISA-18.2 shelving)
        add("dcl.shelve.missalarm", "%SHELVE-W-MISSING, specify  SHELVE ALARM <id>",
                                    "%SHELVE-W-MISSING, préciser  SHELVE ALARM <id>")
        add("dcl.shelve.missid",    "%SHELVE-W-NOID, missing alarm id -- SHELVE ALARM <id>",
                                    "%SHELVE-W-NOID, id d'alarme manquant -- SHELVE ALARM <id>")
        // Consumed via String(format:), so the leading VMS facility code is
        // escaped as %%SHELVE (the .missalarm/.missid variants above are output
        // directly and keep their single %); otherwise the %S in "%SHELVE" is
        // read as a printf conversion and String(format:) traps on the argument.
        add("dcl.shelve.ok",        "%%SHELVE-S-SHELVED, alarm %@ shelved (removed from annunciator)",
                                    "%%SHELVE-S-SHELVED, alarme %@ masquée (retirée de l'annonciateur)")
        add("dcl.unshelve.missalarm","%UNSHELVE-W-MISSING, specify  UNSHELVE ALARM <id>",
                                    "%UNSHELVE-W-MISSING, préciser  UNSHELVE ALARM <id>")
        add("dcl.unshelve.missid",  "%UNSHELVE-W-NOID, missing alarm id -- UNSHELVE ALARM <id>",
                                    "%UNSHELVE-W-NOID, id d'alarme manquant -- UNSHELVE ALARM <id>")
        // Also consumed via String(format:) -- escape the leading % as %%UNSHELVE.
        add("dcl.unshelve.ok",      "%%UNSHELVE-S-RESTORED, alarm %@ returned to annunciator",
                                    "%%UNSHELVE-S-RESTORED, alarme %@ rétablie sur l'annonciateur")
        // SET STANDARD (ASME / EN 81 terminology toggle)
        add("dcl.set.standard.usage","%SET-W-STD, usage: SET STANDARD ASME | EN81 | AUTO",
                                    "%SET-W-STD, usage : SET STANDARD ASME | EN81 | AUTO")
        // .bad and .ok are consumed via String(format:) -- escape the leading
        // % as %%SET (the .usage variant above is output directly); otherwise
        // the %S in "%SET" is read as a printf conversion and String(format:) traps.
        add("dcl.set.standard.bad", "%%SET-W-STD, unknown standard \\%@\\ -- use ASME, EN81 or AUTO",
                                    "%%SET-W-STD, norme inconnue \\%@\\ -- utiliser ASME, EN81 ou AUTO")
        add("dcl.set.standard.ok",  "%%SET-I-STD, safety terminology set to %@ (%@)",
                                    "%%SET-I-STD, terminologie de sécurité réglée sur %@ (%@)")
        add("dcl.set.standard.followlang","following language",              "suit la langue")
        add("dcl.set.standard.override",  "operator override",               "forcé par l'opérateur")
        add("dcl.status.standard",  "  Safety standard: %@ (%@)",            "  Norme de sécurité : %@ (%@)")
        add("dcl.page.more",        "  -- More -- (%d/%d lines, RETURN = next page, Q = quit) ",
                                    "  -- Suite -- (%d/%d lignes, RETURN = page suivante, Q = quitter) ")
        // Safety-chain contact names -- standard-variant (SHOW MODBUS / labels)
        add("safety.contact.doorinterlock.asme", "Door interlock",          "Verrouillage de porte")
        add("safety.contact.doorinterlock.en81", "Door interlock (EN 81-20 §5.3)", "Verrouillage de porte (EN 81-20 §5.3)")
        add("safety.contact.finallimit.asme",    "Terminal (final) limit",  "Fin de course extrême")
        add("safety.contact.finallimit.en81",    "Final limit switch",      "Fin de course extrême (EN 81-20 §5.3.9)")
        add("safety.contact.governor.asme",       "Overspeed governor",     "Limiteur de vitesse")
        add("safety.contact.governor.en81",       "Overspeed governor (limiteur)", "Limiteur de vitesse (EN 81-20 §5.6.2)")
        add("safety.contact.gear.asme",           "Car safety (safeties)",  "Parachute")
        add("safety.contact.gear.en81",           "Safety gear (parachute)","Parachute (EN 81-20 §5.6.2)")
        add("safety.contact.brake.asme",          "Brake proven",           "Frein confirmé")
        add("safety.contact.brake.en81",          "Brake proven",           "Frein confirmé")
        add("safety.contact.chain.asme",          "Safety string intact",   "Chaîne de sécurité intègre")
        add("safety.contact.chain.en81",          "Safety chain intact",    "Chaîne de sécurité intègre")
        // Fire-recall label -- standard-variant (SHOW STATUS building-mode line)
        add("safety.fire.asme",     "Phase I Fire Service Recall",          "Rappel pompiers Phase I")
        add("safety.fire.en81",     "Firefighters' recall (EN 81-73)",      "Rappel pompiers (EN 81-73)")
        add("dcl.ack.nosystem",     "%ACK-W-NOSYSTEM, elevator world is not attached",
                                    "%ACK-W-NOSYSTEM, monde ascenseur non attaché")
        add("dcl.ack.missalarm",    "%ACK-W-MISSALARM, specify ACKNOWLEDGE ALARM <id> or ACKNOWLEDGE ALARM ALL",
                                    "%ACK-W-MISSALARM, spécifiez ACKNOWLEDGE ALARM <id> ou ACKNOWLEDGE ALARM ALL")
        add("dcl.ack.missid",       "%ACK-W-MISSID, missing alarm id or ALL",
                                    "%ACK-W-MISSID, identifiant d'alarme manquant ou ALL")
        add("dcl.ack.alarms.one",   "%ACK-S-ALARMS, 1 active alarm acknowledged",
                                    "%ACK-S-ALARMS, 1 alarme active acquittée")
        // These four are consumed via String(format:), so the leading VMS
        // facility code must be escaped as %% (matching the %%LPDCP messages
        // below); otherwise the %A in "%ACK" is read as a printf conversion
        // and String(format:) traps on the argument-type mismatch.
        add("dcl.ack.alarms.many",  "%%ACK-S-ALARMS, %d active alarms acknowledged",
                                    "%%ACK-S-ALARMS, %d alarmes actives acquittées")
        add("dcl.ack.invalid",      "%%ACK-W-IVID, invalid alarm id %@",
                                    "%%ACK-W-IVID, identifiant d'alarme invalide %@")
        add("dcl.ack.alarm",        "%%ACK-S-ALARM, alarm %@ acknowledged",
                                    "%%ACK-S-ALARM, alarme %@ acquittée")
        add("dcl.ack.notfound",     "%%ACK-W-NOTFOUND, active alarm %@ was not found",
                                    "%%ACK-W-NOTFOUND, alarme active %@ introuvable")

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
        // Only the label-field heading ("<column1>  Test"). The Reading and
        // Status headings are appended in code (refreshTestDisplay) so they
        // stay aligned with the row field widths regardless of language.
        add("diag.col.cab",         "Cab     Test",                        "Cabine  Test")
        add("diag.col.floor",       "Floor   Test",                        "Étage   Test")
        add("diag.col.reading",     "Reading",                             "Mesure")
        add("diag.col.status",      "Status",                              "Statut")
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
        add("diag.test.door",       "DOOR CYCLE & OBSTRUCTION TEST",       "TEST CYCLE PORTES + CAPTEUR D'OBSTRUCTION")
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
        add("login.lpd.help",       "Type HELP RUN for the test menu, HELP LPDCP for cab and building control. Ctrl/Y aborts.",
                                    "Tapez HELP RUN pour les tests, HELP LPDCP pour le contrôle des cabines. Ctrl/Y pour annuler.")
        add("login.lpd.ctrl",       "LPDCP V1.4    --  cab and building control program loaded",
                                    "LPDCP V1.4    --  programme de contrôle cabines / bâtiment chargé")

        // LPD-CP (LPD Elevator Control Program) localized output.  Same
        // rationale as LPD-DIAG above -- a French vendor's layered product
        // would ship localised even though the underlying VMS messages
        // stay English.
        add("lpdcp.err.ivverb",       "%%LPDCP-W-IVVERB, unrecognized LPDCP subverb \\%@\\\n   Valid: SHOW, SET, HELP\n",
                                      "%%LPDCP-W-IVVERB, sous-verbe LPDCP inconnu \\%@\\\n   Valides : SHOW, SET, HELP\n")
        add("lpdcp.err.show.missqual","%LPDCP-W-MISSQUAL, LPDCP SHOW needs a subject\n   Valid: CAB, BUILDING, DISPATCH, CALLS, LOAD\n",
                                      "%LPDCP-W-MISSQUAL, LPDCP SHOW exige un objet\n   Valides : CAB, BUILDING, DISPATCH, CALLS, LOAD\n")
        add("lpdcp.err.show.ivkeyw",  "%%LPDCP-W-IVKEYW, no such LPDCP SHOW subject \\%@\\\n",
                                      "%%LPDCP-W-IVKEYW, objet LPDCP SHOW inconnu \\%@\\\n")
        add("lpdcp.err.set.missqual", "%LPDCP-W-MISSQUAL, LPDCP SET needs a subject\n   Valid: CAB, BUILDING\n",
                                      "%LPDCP-W-MISSQUAL, LPDCP SET exige un objet\n   Valides : CAB, BUILDING\n")
        add("lpdcp.err.set.ivkeyw",   "%%LPDCP-W-IVKEYW, no such LPDCP SET subject \\%@\\\n",
                                      "%%LPDCP-W-IVKEYW, objet LPDCP SET inconnu \\%@\\\n")

        // Per-cab status sheet (LPDCP SHOW CAB <label>).
        add("lpdcp.cab.title",        "\n  Cab %@ -- %@\n\n",
                                      "\n  Cabine %@ -- %@\n\n")
        add("lpdcp.cab.position",     "    Position:     ",
                                      "    Position :    ")
        add("lpdcp.cab.velocity",     "    Velocity:     ",
                                      "    Vitesse :     ")
        add("lpdcp.cab.profile",      "    Profile:      ",
                                      "    Profil :      ")
        add("lpdcp.cab.doors",        "    Doors:        ",
                                      "    Portes :      ")
        add("lpdcp.cab.load",         "    Load:         ",
                                      "    Charge :      ")
        add("lpdcp.cab.mode",         "    Mode:         ",
                                      "    Mode :        ")
        add("lpdcp.cab.queue",        "    Queue:        ",
                                      "    File :        ")
        add("lpdcp.cab.owner",        "    Owner:        ",
                                      "    Propriétaire :")
        add("lpdcp.cab.empty",        "(empty)",
                                      "(vide)")
        add("lpdcp.cab.rated",        "%.0f kg (rated %.0f)",
                                      "%.0f kg (nominal %.0f)")

        add("lpdcp.door.open",        "OPEN",       "OUVERTES")
        add("lpdcp.door.closed",      "CLOSED",     "FERMÉES")
        add("lpdcp.door.opening",     "OPENING",    "OUVERTURE")
        add("lpdcp.door.closing",     "CLOSING",    "FERMETURE")

        add("lpdcp.profile.pax",      "PASSENGER",  "PASSAGERS")
        add("lpdcp.profile.freight",  "FREIGHT",    "FRET")

        add("lpdcp.mode.phase2",      "PHASE II FIRE SERVICE",  "SERVICE INCENDIE PHASE II")
        add("lpdcp.mode.indep",       "INDEPENDENT SERVICE",    "SERVICE INDÉPENDANT")
        add("lpdcp.mode.auto",        "AUTOMATIC",              "AUTOMATIQUE")
        add("lpdcp.mode.manual",      "MANUAL",                 "MANUEL")

        add("lpdcp.owner.local",      "LOCAL",      "LOCAL")
        add("lpdcp.owner.remote",     "REMOTE",     "DISTANT")

        // Building summary (LPDCP SHOW BUILDING).
        add("lpdcp.bldg.title",       "\n  Building summary -- %@\n\n",
                                      "\n  Synthèse du bâtiment -- %@\n\n")
        add("lpdcp.bldg.safety",      "    Safety mode:   ",
                                      "    Mode sécurité :")
        add("lpdcp.bldg.dispatch",    "    Dispatch:      ",
                                      "    Régulation :   ")
        add("lpdcp.bldg.recall",      "    Recall floor:  ",
                                      "    Étage rappel : ")
        add("lpdcp.bldg.cabs",        "    Cabs:          %d registered\n",
                                      "    Cabines :      %d enregistrées\n")
        add("lpdcp.bldg.mode.normal", "NORMAL",                                   "NORMAL")
        add("lpdcp.bldg.mode.fire",   "PHASE I FIRE SERVICE -- recall floor %d",
                                      "SERVICE INCENDIE PHASE I -- étage de rappel %d")
        add("lpdcp.bldg.mode.epo",    "EMERGENCY POWER OPERATION",
                                      "FONCTIONNEMENT SUR SECOURS")
        add("lpdcp.bldg.disp.dest",   "DESTINATION",                              "DESTINATION")
        add("lpdcp.bldg.disp.coll",   "COLLECTIVE",                               "COLLECTIVE")

        // Synopsis printed when LPDCP is invoked with no subverb.
        add("lpdcp.synopsis",
            """

              LPD-CP  LPD Elevator Control Program  V1.4
              (C) 2026  LPD - LEVAGE & PORTES DAUPHINÉ

              Usage:  $ LPDCP <subverb> <noun> [args] [/qualifiers]

              Subverbs:
                SHOW    Display elevator state
                SET     Modify elevator state
                HELP    Detailed command reference
            """,
            """

              LPD-CP  Programme de contrôle ascenseurs LPD  V1.4
              (C) 2026  LPD - LEVAGE & PORTES DAUPHINÉ

              Usage :  $ LPDCP <sous-verbe> <objet> [args] [/qualif]

              Sous-verbes :
                SHOW    Afficher l'état des ascenseurs
                SET     Modifier l'état des ascenseurs
                HELP    Référence détaillée des commandes
            """)

        // Detailed reference (LPDCP HELP).
        add("lpdcp.help.body",
            """

              SHOW subjects:
                CAB [label]     Per-cab status, or list all cabs when no label.
                BUILDING        Safety mode, dispatch mode, recall floor.
                DISPATCH        Group dispatch mode + recent allocations.
                CALLS           Latched hall calls and per-cab car-call queues.
                LOAD            Platform load-cell readouts.

              SET subjects:
                CAB <label>     /MANUAL | /AUTOMATIC | /PAX | /FREIGHT
                                /PHASE2=ON|OFF | /INDEPENDENT=ON|OFF | /LOAD=<kg>
                BUILDING        /FIRE_RECALL=ON|OFF [/FLOOR=n]
                                /EPO=ON|OFF [/CAB=<label>]
                                /NORMAL
                                /DISPATCH=COLLECTIVE|DESTINATION

              SYS$LOGIN:LOGIN.COM seeds the foreign-command aliases CAB, BLDG,
              DPATCH, CALLS, LOAD, FIRE and NORMAL for typing convenience.
            """,
            """

              Objets SHOW :
                CAB [étiq.]     État d'une cabine, ou liste toutes les cabines.
                BUILDING        Mode sécurité, mode régulation, étage de rappel.
                DISPATCH        Mode de régulation + allocations récentes.
                CALLS           Appels paliers latchés et files de cabines.
                LOAD            Lecture des capteurs de charge plateforme.

              Objets SET :
                CAB <étiq.>     /MANUAL | /AUTOMATIC | /PAX | /FREIGHT
                                /PHASE2=ON|OFF | /INDEPENDENT=ON|OFF | /LOAD=<kg>
                BUILDING        /FIRE_RECALL=ON|OFF [/FLOOR=n]
                                /EPO=ON|OFF [/CAB=<étiq.>]
                                /NORMAL
                                /DISPATCH=COLLECTIVE|DESTINATION

              SYS$LOGIN:LOGIN.COM initialise les alias de commandes étrangères
              CAB, BLDG, DPATCH, CALLS, LOAD, FIRE et NORMAL pour la frappe rapide.
            """)

        // Downstream LPDCP handlers (SET BUILDING, SET CAB, SHOW DISPATCH,
        // SHOW CALLS, SHOW LOAD). Same EN/FR-on-the-tail, facility-code-stays-
        // English pattern as the lpdcp.err.* messages above.
        add("lpdcp.cmd.noworld",
            "%CTRL-E-NOWORLD, no world\n",
            "%CTRL-E-NOWORLD, aucun monde\n")
        add("lpdcp.cmd.sysnoworld",
            "%SYSTEM-F-NOWORLD, elevator world not attached\n",
            "%SYSTEM-F-NOWORLD, monde ascenseur non rattaché\n")
        add("lpdcp.cmd.shownoworld",
            "%SHOW-W-NOWORLD, elevator world not attached\n",
            "%SHOW-W-NOWORLD, monde ascenseur non rattaché\n")

        // SET BUILDING
        add("lpdcp.bldg.modenormal",
            "%CTRL-S-MODE, building returned to normal operation\n",
            "%CTRL-S-MODE, bâtiment revenu en service normal\n")
        add("lpdcp.bldg.dispkeyw",
            "%DCL-W-IVKEYW, /DISPATCH expects COLLECTIVE or DESTINATION\n",
            "%DCL-W-IVKEYW, /DISPATCH attend COLLECTIVE ou DESTINATION\n")
        add("lpdcp.bldg.dispdest",
            "%CTRL-S-DISPATCH, destination dispatch enabled -- CALL DESTINATION /FROM=<n> /TO=<m>\n",
            "%CTRL-S-DISPATCH, régulation destination activée -- CALL DESTINATION /FROM=<n> /TO=<m>\n")
        add("lpdcp.bldg.dispcoll",
            "%CTRL-S-DISPATCH, collective control restored\n",
            "%CTRL-S-DISPATCH, contrôle collectif rétabli\n")
        add("lpdcp.bldg.fireon",
            "%%CTRL-W-FIRERECALL, Phase I Fire Service active -- all cabs recall to floor %d\n",
            "%%CTRL-W-FIRERECALL, Service Incendie Phase I actif -- rappel de toutes les cabines à l'étage %d\n")
        add("lpdcp.bldg.fireoff",
            "%CTRL-S-FIRERESET, Phase I Fire Service released\n",
            "%CTRL-S-FIRERESET, Service Incendie Phase I libéré\n")
        add("lpdcp.bldg.epoon",
            "%%CTRL-W-EPO, Emergency Power Operation -- only cab %@ remains on backup\n",
            "%%CTRL-W-EPO, Fonctionnement Secours -- seule la cabine %@ reste sur batterie\n")
        add("lpdcp.bldg.epoff",
            "%CTRL-S-EPORESET, Emergency Power Operation released\n",
            "%CTRL-S-EPORESET, Fonctionnement Secours libéré\n")
        add("lpdcp.bldg.missqual",
            "%DCL-W-MISSQUAL, SET BUILDING needs /FIRE_RECALL, /EPO, or /NORMAL\n",
            "%DCL-W-MISSQUAL, SET BUILDING attend /FIRE_RECALL, /EPO ou /NORMAL\n")
        add("lpdcp.bldg.none",
            "(none)",
            "(aucune)")

        // SET CAB
        add("lpdcp.cab.misscab",
            "%SET-W-MISSCAB, missing cab identifier\n",
            "%SET-W-MISSCAB, identifiant de cabine manquant\n")
        add("lpdcp.cab.nosuch",
            "%%SET-W-NOSUCHCAB, no such cab \\%@\\\n",
            "%%SET-W-NOSUCHCAB, cabine \\%@\\ inconnue\n")
        add("lpdcp.cab.remote",
            "%%SET-W-REMOTE, cab %@ is owned by a remote node\n",
            "%%SET-W-REMOTE, cabine %@ appartient à un nœud distant\n")
        add("lpdcp.cab.noauto",
            "%SET-F-NOAUTO, automation subsystem not running\n",
            "%SET-F-NOAUTO, sous-système d'automatisation arrêté\n")
        add("lpdcp.cab.man.set",
            "%%SET-I-CABMAN, cab %@ released from auto-dispatch -- MANUAL CONTROL\n",
            "%%SET-I-CABMAN, cabine %@ retirée de l'auto-régulation -- CONTRÔLE MANUEL\n")
        add("lpdcp.cab.man.nochg",
            "%%SET-I-NOCHG, cab %@ was already under manual control\n",
            "%%SET-I-NOCHG, cabine %@ déjà en contrôle manuel\n")
        add("lpdcp.cab.auto.set",
            "%%SET-I-CABAUTO, cab %@ returned to auto-dispatch\n",
            "%%SET-I-CABAUTO, cabine %@ remise en auto-régulation\n")
        add("lpdcp.cab.auto.nochg",
            "%%SET-I-NOCHG, cab %@ was already under auto-dispatch\n",
            "%%SET-I-NOCHG, cabine %@ déjà en auto-régulation\n")
        add("lpdcp.cab.pax.nochg",
            "%%SET-I-NOCHG, cab %@ was already PAX\n",
            "%%SET-I-NOCHG, cabine %@ déjà en mode PASSAGERS\n")
        add("lpdcp.cab.pax.set",
            "%%SET-I-CABPAX, cab %@ profile set to PASSENGER\n",
            "%%SET-I-CABPAX, profil de la cabine %@ réglé sur PASSAGERS\n")
        add("lpdcp.cab.frt.nochg",
            "%%SET-I-NOCHG, cab %@ was already FREIGHT\n",
            "%%SET-I-NOCHG, cabine %@ déjà en mode FRET\n")
        add("lpdcp.cab.frt.set",
            "%%SET-I-CABFRT, cab %@ profile set to FREIGHT\n",
            "%%SET-I-CABFRT, profil de la cabine %@ réglé sur FRET\n")
        add("lpdcp.cab.phase2.on",
            "%%SET-W-PHASE2, cab %@ in Phase II Fire Service -- fireman's operation\n",
            "%%SET-W-PHASE2, cabine %@ en Service Incendie Phase II -- opération pompier\n")
        add("lpdcp.cab.phase2.off",
            "%%SET-I-PHASE2OFF, cab %@ Phase II Fire Service released\n",
            "%%SET-I-PHASE2OFF, Service Incendie Phase II libéré sur cabine %@\n")
        add("lpdcp.cab.indep.on",
            "%%SET-I-INDEP, cab %@ in Independent Service -- doors held open, no group dispatch\n",
            "%%SET-I-INDEP, cabine %@ en Service Indépendant -- portes ouvertes, hors régulation\n")
        add("lpdcp.cab.indep.off",
            "%%SET-I-INDEPOFF, cab %@ returned to normal group dispatch\n",
            "%%SET-I-INDEPOFF, cabine %@ remise en régulation de groupe\n")
        add("lpdcp.cab.load.set",
            "%%SET-I-LOAD, cab %@ platform load now %.0f kg (%.0f%% of rated)\n",
            "%%SET-I-LOAD, charge plateforme cabine %@ : %.0f kg (%.0f%% du nominal)\n")
        add("lpdcp.cab.missqual",
            "%SET-W-MISSQUAL, SET CAB needs /MANUAL, /AUTOMATIC, /PAX, /FREIGHT, /PHASE2, /INDEPENDENT or /LOAD\n",
            "%SET-W-MISSQUAL, SET CAB attend /MANUAL, /AUTOMATIC, /PAX, /FREIGHT, /PHASE2, /INDEPENDENT ou /LOAD\n")

        // SHOW LOAD
        add("lpdcp.load.title",
            "\n  Cab platform load cells -- %@\n\n",
            "\n  Capteurs de charge plateforme -- %@\n\n")
        add("lpdcp.load.header",
            "    Cab        Load (kg)   Rated   Pct      State\n",
            "    Cabine     Charge (kg) Nominal Pourc.   État\n")
        add("lpdcp.load.sep",
            "    ---------  ---------   -----   -----    --------\n",
            "    ---------  ---------   ------- -------  --------\n")
        add("lpdcp.load.nocabs",
            "    (no cabs registered)\n",
            "    (aucune cabine enregistrée)\n")
        add("lpdcp.load.state.overload", "OVERLOAD", "SURCHARGE")
        add("lpdcp.load.state.full",     "FULL",     "PLEIN")
        add("lpdcp.load.state.empty",    "EMPTY",    "VIDE")
        add("lpdcp.load.state.nominal",  "NOMINAL",  "NOMINAL")

        // SHOW CALLS
        add("lpdcp.calls.hall.title",
            "\n  Active landing-fixture (hall) calls:\n",
            "\n  Appels palier (boîtier de palier) actifs :\n")
        add("lpdcp.calls.hall.header",
            "    Seq   Floor  Dir  Assigned cab\n",
            "    Séq   Étage  Dir  Cabine attribuée\n")
        add("lpdcp.calls.hall.sep",
            "    ----  -----  ---  ----------------\n",
            "    ----  -----  ---  ----------------\n")
        add("lpdcp.calls.hall.none",
            "    (none)\n",
            "    (aucun)\n")
        add("lpdcp.calls.hall.up",  "UP ", "HT ")
        add("lpdcp.calls.hall.dn",  "DN ", "BS ")
        add("lpdcp.calls.hall.unassigned", "(unassigned)", "(non attribuée)")
        add("lpdcp.calls.car.title",
            "\n  In-cab (car) call queues:\n",
            "\n  Files d'appels en cabine :\n")
        add("lpdcp.calls.car.header",
            "    Cab        Queue\n",
            "    Cabine     File\n")
        add("lpdcp.calls.car.sep",
            "    ---------  ---------------------------------\n",
            "    ---------  ---------------------------------\n")
        add("lpdcp.calls.car.nocabs",
            "    (no local cabs)\n",
            "    (aucune cabine locale)\n")
        add("lpdcp.calls.car.empty", "(empty)", "(vide)")

        // SHOW DISPATCH
        add("lpdcp.disp.mode",
            "\n  Group dispatch mode: ",
            "\n  Mode de régulation de groupe : ")
        add("lpdcp.disp.dest",
            "DESTINATION  (lobby keypad allocates per-call)\n",
            "DESTINATION  (clavier hall, allocation par appel)\n")
        add("lpdcp.disp.coll",
            "COLLECTIVE   (per-cab queues, traditional hall buttons)\n",
            "COLLECTIVE   (files par cabine, boutons palier classiques)\n")
        add("lpdcp.disp.recent.title",
            "\n  Recent destination-dispatch allocations:\n",
            "\n  Allocations récentes de régulation destination :\n")
        add("lpdcp.disp.recent.header",
            "    Seq   Time                     From  To   Cab        ETA\n",
            "    Séq   Heure                    Dep.  Arr. Cabine     ETA\n")
        add("lpdcp.disp.recent.sep",
            "    ----  -----------------------  ----  ---  ---------  ------\n",
            "    ----  -----------------------  ----  ---- ---------  ------\n")

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

        // Per-step readings (column is 14 chars wide -- pick translations
        // that fit so French rendering doesn't end up truncated mid-word).
        add("diag.brake.reading.engaged",  "%.1f kN engaged",                "%.1f kN serré")
        add("diag.brake.reading.released", "%.1f kN released",               "%.1f kN desserré")
        add("diag.brake.reading.moving",   "released (moving)",              "desserré (en mvt)")
        add("diag.door.reading.reverse",   "reverse @ 12 mm",                "inv. @ 12 mm")
        add("diag.door.reading.armed",     "armed (idle)",                   "armé (inactif)")
        add("diag.door.reading.idleSuffix"," (idle)",                        " (inactif)")
        add("diag.lamp.reading.lit",       "up+dn lit",                      "HT+BS allumés")
        add("diag.reading.noCab",          "(no cab)",                       "(aucune cabine)")
        add("diag.reading.noWorld",        "(no world)",                     "(aucun monde)")
        add("diag.weight.reading.records", "%d records",                     "%d entrées")
        add("diag.lamp.localonly",
            "%HALL_LAMP-I-LOCAL, hall-lamp test runs on the local landing fixtures only",
            "%HALL_LAMP-I-LOCAL, le test des lanternes ne s'exécute que sur les paliers locaux")

        return t
    }

    static func lookup(_ key: String, lang: Lang) -> String {
        if let row = table[key], let value = row[lang] { return value }
        if let row = table[key], let fallback = row[.en] { return fallback }
        return key
    }
}
