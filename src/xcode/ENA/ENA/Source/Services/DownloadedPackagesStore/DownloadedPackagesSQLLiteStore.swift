// Corona-Warn-App
//
// SAP SE and all other contributors
// copyright owners license this file to you under the Apache
// License, Version 2.0 (the "License"); you may not use this
// file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import FMDB
import Foundation

final class DownloadedPackagesSQLLiteStore {
	// MARK: Creating a Store

	init(database: FMDatabase) {
		self.database = database
	}

	private func beginTransaction() {
		database.beginExclusiveTransaction()
	}

	private func commit() {
		database.commit()
	}

	// MARK: Properties

	private let database: FMDatabase
}

extension DownloadedPackagesSQLLiteStore: DownloadedPackagesStore {
	func open() {
		database.open()
		database.executeStatements(
			"""
			    PRAGMA locking_mode=EXCLUSIVE;
			    PRAGMA auto_vacuum=2;
			    PRAGMA journal_mode=WAL;

			    CREATE TABLE IF NOT EXISTS
			        Z_DOWNLOADED_PACKAGE (
			        Z_BIN BLOB NOT NULL,
			        Z_SIGNATURE BLOB NOT NULL,
			        Z_DAY TEXT NOT NULL,
			        Z_HOUR INTEGER,
			        PRIMARY KEY (
			            Z_DAY,
			            Z_HOUR
			        )
			    );
			"""
		)
	}

	func close() {
		database.close()
	}

	// swiftlint:disable:next function_body_length
	func set(
		day: String,
		package: SAPDownloadedPackage
	) {
		func deleteHours() -> Bool {
			database.executeUpdate(
				"""
				    DELETE FROM Z_DOWNLOADED_PACKAGE
				    WHERE
				        Z_DAY = :day AND
				        Z_HOUR IS NOT NULL
				    ;
				""",
				withParameterDictionary: ["day": day]
			)
		}
		func insertDay() -> Bool {
			database.executeUpdate(
				"""
				    INSERT INTO
				        Z_DOWNLOADED_PACKAGE (
				            Z_BIN,
				            Z_SIGNATURE,
				            Z_DAY,
				            Z_HOUR
				        )
				        VALUES (
				            :bin,
				            :signature,
				            :day,
				            NULL
				        )
				        ON CONFLICT (
				            Z_DAY,
				            Z_HOUR
				        )
				        DO UPDATE SET
				            Z_BIN = :bin,
				            Z_SIGNATURE = :signature
				    ;
				""",
				withParameterDictionary: [
					"bin": package.bin,
					"signature": package.signature,
					"day": day
				]
			)
		}

		beginTransaction()

		guard deleteHours() else {
			database.rollback()
			return
		}
		guard insertDay() else {
			database.rollback()
			return
		}

		database.commit()
	}

	func set(hour: Int, day: String, package: SAPDownloadedPackage) {
		let sql = """
		    INSERT INTO Z_DOWNLOADED_PACKAGE(
		        Z_BIN,
		        Z_SIGNATURE,
		        Z_DAY,
		        Z_HOUR
		    )
		    VALUES (
		        :bin,
		        :signature,
		        :day,
		        :hour
		    )
		    ON CONFLICT(
		        Z_DAY,
		        Z_HOUR
		    )
		    DO UPDATE SET
		        Z_BIN = :bin,
		        Z_SIGNATURE = :signature
		    ;
		"""
		let parameters: [String: Any] = [
			"bin": package.bin,
			"signature": package.signature,
			"day": day,
			"hour": hour
		]
		database.executeUpdate(sql, withParameterDictionary: parameters)
	}

	func package(for day: String) -> SAPDownloadedPackage? {
		let sql = """
		    SELECT
		        Z_BIN,
		        Z_SIGNATURE
		    FROM Z_DOWNLOADED_PACKAGE
		    WHERE
		        Z_DAY = :day AND
		        Z_HOUR IS NULL
		    ;
		"""
		guard let result = database.execute(query: sql, parameters: ["day": day]) else {
			return nil
		}

		defer { result.close() }
		return result
			.map { $0.downloadedPackage() }
			.compactMap { $0 }
			.first
	}

	func hourlyPackages(for day: String) -> [SAPDownloadedPackage] {
		let sql = "SELECT Z_BIN, Z_SIGNATURE, Z_HOUR FROM Z_DOWNLOADED_PACKAGE WHERE Z_DAY = :day AND Z_HOUR IS NOT NULL ORDER BY Z_HOUR DESC;"
		guard let result = database.execute(query: sql, parameters: ["day": day]) else {
			return []
		}
		defer { result.close() }
		return result
			.map { $0.downloadedPackage() }
			.compactMap { $0 }
	}

	func allDays() -> [String] {
		let sql = "SELECT Z_DAY FROM Z_DOWNLOADED_PACKAGE WHERE Z_HOUR IS NULL;"
		guard let result = database.execute(query: sql) else {
			return []
		}
		defer { result.close() }
		return result
			.map { $0.string(forColumn: "Z_DAY") }
			.compactMap { $0 }
	}

	func hours(for day: String) -> [Int] {
		let sql =
			"""
			    SELECT
			        Z_HOUR
			    FROM
			        Z_DOWNLOADED_PACKAGE
			    WHERE
			        Z_HOUR IS NOT NULL AND Z_DAY = :day
			    ;
			"""
		guard let result = database.execute(query: sql, parameters: ["day": day]) else {
			return []
		}
		defer { result.close() }
		return result.map { Int($0.int(forColumn: "Z_HOUR")) }
	}

	func reset() {
		database.executeStatements(
			"""
			    PRAGMA journal_mode=OFF;
			    DROP TABLE Z_DOWNLOADED_PACKAGE;
			"""
		)
		close()
	}
}

private extension FMDatabase {
	func execute(
		query sql: String,
		parameters: [AnyHashable: Any] = [:]
	) -> FMResultSet? {
		executeQuery(sql, withParameterDictionary: parameters)
	}
}

private extension FMResultSet {
	func map<T>(transform: (FMResultSet) -> T) -> [T] {
		var mapped = [T]()
		while next() {
			mapped.append(transform(self))
		}
		return mapped
	}

	func downloadedPackage() -> SAPDownloadedPackage? {
		guard
			let bin = data(forColumn: "Z_BIN"),
			let signature = data(forColumn: "Z_SIGNATURE") else {
			return nil
		}
		return SAPDownloadedPackage(keysBin: bin, signature: signature)
	}
}
