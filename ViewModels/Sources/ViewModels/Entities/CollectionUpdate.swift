// Copyright © 2020 Metabolist. All rights reserved.

public struct CollectionUpdate: Hashable {
    public let sections: [CollectionSection]
    public let maintainScrollPositionItemId: String?
    public let shouldAdjustContentInset: Bool
}
