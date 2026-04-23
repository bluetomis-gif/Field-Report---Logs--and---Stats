//
//  Item.swift
//  FieldReport: Logs and Stats
//
//  Created by Adi D on 4/23/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
