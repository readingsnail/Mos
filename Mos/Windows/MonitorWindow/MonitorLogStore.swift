//
//  MonitorLogStore.swift
//  Mos
//

import Foundation

enum MonitorLogChannel: String, CaseIterable {
    case buttonEvent = "Button Event"
}

final class MonitorLogStore {

    private let previewLineLimit: Int
    private var linesByChannel: [MonitorLogChannel: [String]] = [:]

    init(previewLineLimit: Int = 200) {
        self.previewLineLimit = max(1, previewLineLimit)
    }

    func append(_ line: String, to channel: MonitorLogChannel) {
        guard !line.isEmpty else { return }
        linesByChannel[channel, default: []].append(line)
    }

    func previewText(for channel: MonitorLogChannel) -> String {
        let lines = linesByChannel[channel] ?? []
        return lines.suffix(previewLineLimit).reversed().joined(separator: "\n")
    }

    func exportText(for channel: MonitorLogChannel) -> String {
        (linesByChannel[channel] ?? []).joined(separator: "\n")
    }

    func clear(_ channel: MonitorLogChannel? = nil) {
        guard let channel else {
            linesByChannel.removeAll()
            return
        }
        linesByChannel[channel] = []
    }
}
