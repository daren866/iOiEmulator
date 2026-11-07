import Foundation

/// qemu-ios 的机器列表（来源：blake-lucas/qemu-ios README 的 `-M` 表）。
/// 当前仅作目录数据，尚未链接到任何可启动的引擎。
struct Board: Identifiable, Hashable {
    var id: String { machine }
    let machine: String
    let device: String
    let boardId: String
    let soc: String
    let guestArch: String
    let firmware: String
}

enum BoardCatalog {
    static let all: [Board] = [
        Board(machine: "iPod-Touch-1G", device: "iPod touch 1G", boardId: "n45ap",
              soc: "S5L8900", guestArch: "armv6", firmware: "iPhone OS 1.1–1.1.5"),
        Board(machine: "iPhone-2G", device: "iPhone (初代)", boardId: "m68ap",
              soc: "S5L8900", guestArch: "armv6", firmware: "iPhone OS 1.0"),
        Board(machine: "iPod-Touch", device: "iPod touch 2G", boardId: "n72ap",
              soc: "S5L8720", guestArch: "armv6", firmware: "iPhone OS 2.1.1–iOS 4.2.1"),
        Board(machine: "n18", device: "iPod touch 3G", boardId: "n18ap",
              soc: "S5L8922", guestArch: "armv7", firmware: "iPhone OS 3.1.1–iOS 5.1.1"),
        Board(machine: "n88", device: "iPhone 3GS", boardId: "n88ap",
              soc: "S5L8920", guestArch: "armv7", firmware: "iPhone OS 3.0–iOS 6.1.6"),
        Board(machine: "iPod-Touch-4G", device: "iPod touch 4G", boardId: "n81ap",
              soc: "A4 (S5L8930)", guestArch: "armv7", firmware: "iOS 4.1–6.1.6"),
        Board(machine: "iPhone-4", device: "iPhone 4 (GSM)", boardId: "n90ap",
              soc: "A4 (S5L8930)", guestArch: "armv7", firmware: "iOS 4.0–7.1.2"),
        Board(machine: "ipad1", device: "iPad (初代)", boardId: "k48ap",
              soc: "A4 (S5L8930)", guestArch: "armv7", firmware: "iPhone OS 3.2–iOS 5.1.1")
    ]
}
