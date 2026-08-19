// Registers a bundle id as the default handler for terminal-ish content types and URL schemes.
// usage: set-default <bundle-id>
import Foundation
import CoreServices

let bundleId = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.cwandt.knifeterminal"
let utis = ["com.apple.terminal.shell-script", "public.shell-script", "public.unix-executable", "public.bash-script", "public.zsh-script"]
let schemes = ["ssh", "telnet", "x-man-page"]
var failures = 0
for u in utis {
  let r = LSSetDefaultRoleHandlerForContentType(u as CFString, .all, bundleId as CFString)
  print("\(r == 0 ? "ok " : "ERR") uti    \(u) (\(r))"); if r != 0 { failures += 1 }
}
for s in schemes {
  let r = LSSetDefaultHandlerForURLScheme(s as CFString, bundleId as CFString)
  print("\(r == 0 ? "ok " : "ERR") scheme \(s) (\(r))"); if r != 0 { failures += 1 }
}
exit(failures == 0 ? 0 : 1)
