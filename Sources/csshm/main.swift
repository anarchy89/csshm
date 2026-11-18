// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CsshmCore

let options: Options
do {
    options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    warn("\(error)")
    die("run \"csshm --help\" for the options", code: 2)
}

if options.help {
    print(Launcher.usage)
    exit(0)
}
if options.version {
    print("csshm \(csshmVersion)")
    exit(0)
}

if options.update {
    Updater.run()
}

if options.probeScreens {
    TerminalBackend.printProbe()
    exit(0)
}

if options.listScreens {
    Launcher.listScreens()
}

if options.master {
    guard let session = options.session else { die("--master needs --session") }
    Master(session: session).run()
} else if options.slave {
    guard let session = options.session, let id = options.slaveID else { die("--slave needs --session and --slaveid") }
    Slave.run(session: session, id: id)
} else {
    Launcher.run(options)
}
