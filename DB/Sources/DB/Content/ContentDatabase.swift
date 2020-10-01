// Copyright © 2020 Metabolist. All rights reserved.

import Combine
import Foundation
import GRDB
import Keychain
import Mastodon
import Secrets

public struct ContentDatabase {
    private let databaseWriter: DatabaseWriter

    public init(identityID: UUID, inMemory: Bool, keychain: Keychain.Type) throws {
        if inMemory {
            databaseWriter = DatabaseQueue()
        } else {
            let path = try Self.fileURL(identityID: identityID).path
            var configuration = Configuration()

            configuration.prepareDatabase {
                try $0.usePassphrase(Secrets.databaseKey(identityID: identityID, keychain: keychain))
            }

            databaseWriter = try DatabasePool(path: path, configuration: configuration)
        }

        try migrator.migrate(databaseWriter)
        try clean()
    }
}

public extension ContentDatabase {
    static func delete(forIdentityID identityID: UUID) throws {
        try FileManager.default.removeItem(at: fileURL(identityID: identityID))
    }

    func insert(status: Status) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: status.save)
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func insert(statuses: [Status], timeline: Timeline) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            try timeline.save($0)

            for status in statuses {
                try status.save($0)

                try TimelineStatusJoin(timelineId: timeline.id, statusId: status.id).save($0)
            }
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func insert(context: Context, parentID: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for status in context.ancestors + context.descendants {
                try status.save($0)
            }

            for (section, statuses) in [(StatusContextJoin.Section.ancestors, context.ancestors),
                                        (StatusContextJoin.Section.descendants, context.descendants)] {
                for (index, status) in statuses.enumerated() {
                    try StatusContextJoin(
                        parentId: parentID,
                        statusId: status.id,
                        section: section,
                        index: index)
                        .save($0)
                }

               try StatusContextJoin.filter(
                StatusContextJoin.Columns.parentId == parentID
                    && StatusContextJoin.Columns.section == section.rawValue
                    && !statuses.map(\.id).contains(StatusContextJoin.Columns.statusId))
                    .deleteAll($0)
            }
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func insert(pinnedStatuses: [Status], accountID: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for (index, status) in pinnedStatuses.enumerated() {
                try status.save($0)

                try AccountPinnedStatusJoin(accountId: accountID, statusId: status.id, index: index).save($0)
            }

            try AccountPinnedStatusJoin.filter(
                AccountPinnedStatusJoin.Columns.accountId == accountID
                    && !pinnedStatuses.map(\.id).contains(AccountPinnedStatusJoin.Columns.statusId))
                .deleteAll($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func append(accounts: [Account], toList list: AccountList) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            try list.save($0)

            let count = try list.accounts.fetchCount($0)

            for (index, account) in accounts.enumerated() {
                try account.save($0)
                try AccountListJoin(accountId: account.id, listId: list.id, index: count + index).save($0)
            }
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func setLists(_ lists: [List]) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for list in lists {
                try Timeline.list(list).save($0)
            }

            try TimelineRecord
                .filter(!lists.map(\.id).contains(TimelineRecord.Columns.listId)
                            && TimelineRecord.Columns.listTitle != nil)
                .deleteAll($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func createList(_ list: List) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: Timeline.list(list).save)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func deleteList(id: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: TimelineRecord.filter(TimelineRecord.Columns.listId == id).deleteAll)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func setFilters(_ filters: [Filter]) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for filter in filters {
                try filter.save($0)
            }

            try Filter.filter(!filters.map(\.id).contains(Filter.Columns.id)).deleteAll($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func createFilter(_ filter: Filter) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: filter.save)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func deleteFilter(id: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: Filter.filter(Filter.Columns.id == id).deleteAll)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func statusesObservation(timeline: Timeline) -> AnyPublisher<[[Status]], Error> {
        ValueObservation.tracking { db -> [[StatusInfo]] in
            let statuses = try TimelineRecord(timeline: timeline).statuses.fetchAll(db)

            if case let .profile(accountId, profileCollection) = timeline, profileCollection == .statuses {
                let pinnedStatuses = try AccountRecord.filter(AccountRecord.Columns.id == accountId)
                    .fetchOne(db)?.pinnedStatuses.fetchAll(db) ?? []

                return [pinnedStatuses, statuses]
            } else {
                return [statuses]
            }
        }
        .removeDuplicates()
        .map { $0.map { $0.map(Status.init(info:)) } }
        .publisher(in: databaseWriter)
        .eraseToAnyPublisher()
    }

    func contextObservation(parentID: String) -> AnyPublisher<[[Status]], Error> {
        ValueObservation.tracking { db -> [[StatusInfo]] in
            guard let parent = try StatusInfo.request(StatusRecord.filter(StatusRecord.Columns.id == parentID))
                    .fetchOne(db) else {
                return []
            }

            let ancestors = try parent.record.ancestors.fetchAll(db)
            let descendants = try parent.record.descendants.fetchAll(db)

            return [ancestors, [parent], descendants]
        }
        .removeDuplicates()
        .map { $0.map { $0.map(Status.init(info:)) } }
        .publisher(in: databaseWriter)
        .eraseToAnyPublisher()
    }

    func listsObservation() -> AnyPublisher<[Timeline], Error> {
        ValueObservation.tracking(TimelineRecord.filter(TimelineRecord.Columns.listId != nil)
                                    .order(TimelineRecord.Columns.listTitle.asc)
                                    .fetchAll)
            .removeDuplicates()
            .map { $0.map(Timeline.init(record:)).compactMap { $0 } }
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }

    func activeFiltersObservation(date: Date, context: Filter.Context? = nil) -> AnyPublisher<[Filter], Error> {
        ValueObservation.tracking(
            Filter.filter(Filter.Columns.expiresAt == nil || Filter.Columns.expiresAt > date).fetchAll)
            .removeDuplicates()
            .map {
                guard let context = context else { return $0 }

                return $0.filter { $0.context.contains(context) }
            }
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }

    func expiredFiltersObservation(date: Date) -> AnyPublisher<[Filter], Error> {
        ValueObservation.tracking(Filter.filter(Filter.Columns.expiresAt < date).fetchAll)
            .removeDuplicates()
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }

    func accountObservation(id: String) -> AnyPublisher<Account?, Error> {
        ValueObservation.tracking(AccountInfo.request(AccountRecord.filter(AccountRecord.Columns.id == id)).fetchOne)
            .removeDuplicates()
            .map {
                if let info = $0 {
                    return Account(info: info)
                } else {
                    return nil
                }
            }
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }

    func accountListObservation(_ list: AccountList) -> AnyPublisher<[Account], Error> {
        ValueObservation.tracking(list.accounts.fetchAll)
            .removeDuplicates()
            .map { $0.map(Account.init(info:)) }
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }
}

private extension ContentDatabase {
    static func fileURL(identityID: UUID) throws -> URL {
        try FileManager.default.databaseDirectoryURL(name: identityID.uuidString)
    }

    func clean() throws {
        try databaseWriter.write {
            try TimelineRecord.deleteAll($0)
            try StatusRecord.deleteAll($0)
            try AccountRecord.deleteAll($0)
            try AccountList.deleteAll($0)
        }
    }
}
