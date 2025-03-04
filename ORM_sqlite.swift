import GRDB
import OSLog

// MARK: - Configuration des Erreurs
enum DatabaseError: Error {
    case connectionFailed
    case queryFailed(String)
    case dataNotFound
    case migrationFailed
}

// MARK: - Logger personnalisé
class Logger {
    private let logger = OSLog(subsystem: "com.example.swiftdb", category: "database")
    
    func info(_ message: String) {
        os_log("%{public}@", log: logger, type: .info, message)
    }
    
    func error(_ message: String) {
        os_log("%{public}@", log: logger, type: .error, message)
    }
}

// MARK: - Gestionnaire de Base de Données
class DatabaseManager {
    static let shared = DatabaseManager()
    private var dbQueue: DatabaseQueue?
    private let logger = Logger()
    
    private init() {}
    
    func openDatabase() throws {
        let fileManager = FileManager.default
        guard let documentDirectory = try? fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            logger.error("Failed to get document directory")
            throw DatabaseError.connectionFailed
        }
        
        let dbPath = documentDirectory.appendingPathComponent("mydatabase.sqlite")
        do {
            // Configuration de la base de données
            var config = Configuration()
            config.readonly = false
            config.foreignKeysEnabled = true
            config.label = "com.example.database"
            
            // Création de la queue de base de données
            dbQueue = try DatabaseQueue(path: dbPath.path, configuration: config)
            
            // Appliquer les migrations
            try runMigrations()
            
            logger.info("Database opened successfully at \(dbPath)")
        } catch {
            logger.error("Failed to open database: \(error)")
            throw DatabaseError.connectionFailed
        }
    }
    
    // Migrations de la base de données
    private func runMigrations() throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError.connectionFailed
        }
        
        try dbQueue.write { db in
            var migrator = DatabaseMigrator()
            
            // Migration: Création des tables
            migrator.registerMigration("createTables") { db in
                // Table utilisateurs
                try db.create(table: "users") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("name", .text).notNull()
                    t.column("email", .text).notNull().unique()
                    t.column("created_at", .datetime).notNull().defaults(to: GRDB.Date.now)
                }
                
                // Table profiles
                try db.create(table: "profiles") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("user_id", .integer).notNull().references("users", onDelete: .cascade)
                    t.column("bio", .text)
                    t.column("avatar_url", .text)
                }
            }
            
            try migrator.migrate(db)
        }
    }
    
    func getDBQueue() throws -> DatabaseQueue {
        guard let dbQueue = dbQueue else {
            logger.error("Database not connected")
            throw DatabaseError.connectionFailed
        }
        return dbQueue
    }
}

// MARK: - Modèles de Données (ORM)
struct User: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var email: String
    var createdAt: Date
    
    // Définition des clés pour la correspondance avec la base de données
    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let email = Column("email")
        static let createdAt = Column("created_at")
    }
    
    static let databaseTableName = "users"
    
    // Relation one-to-one avec Profile
    static let profile = hasOne(Profile.self)
}

struct Profile: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var userId: Int64
    var bio: String?
    var avatarUrl: String?
    
    enum Columns {
        static let id = Column("id")
        static let userId = Column("user_id")
        static let bio = Column("bio")
        static let avatarUrl = Column("avatar_url")
    }
    
    static let databaseTableName = "profiles"
    
    // Relation one-to-one avec User
    static let user = belongsTo(User.self)
}

// Modèle qui inclut un utilisateur avec son profil
struct UserWithProfile: FetchableRecord {
    var user: User
    var profile: Profile?
    
    init(row: Row) {
        user = User(row: row)
        profile = row["profile"] is DatabaseValue ? nil : Profile(row: row)
    }
}

// MARK: - DAO (Data Access Object)
class UserDao {
    private let dbQueue: DatabaseQueue
    private let logger = Logger()
    
    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }
    
    func createUser(_ user: User) throws -> User {
        var savedUser = user
        
        try dbQueue.write { db in
            try savedUser.save(db)
            logger.info("User created: \(user.name) with ID: \(String(describing: savedUser.id))")
        }
        
        return savedUser
    }
    
    func fetchUsers() throws -> [User] {
        return try dbQueue.read { db in
            try User.fetchAll(db)
        }
    }
    
    // Exemple de jointure réelle entre User et Profile
    func fetchUsersWithProfile() throws -> [UserWithProfile] {
        return try dbQueue.read { db in
            let request = User
                .joining(optional: User.profile)
                .filter(User.Columns.email.like("%@example.com"))
                .order(User.Columns.name)
            
            return try UserWithProfile.fetchAll(db, request)
        }
    }
    
    // Exemple de transaction
    func createUserWithProfile(user: User, profile: Profile) throws {
        try dbQueue.write { db in
            try db.transaction {
                // Enregistrer l'utilisateur
                var savedUser = user
                try savedUser.save(db)
                
                // Créer et lier le profil
                var userProfile = profile
                userProfile.userId = savedUser.id!
                try userProfile.save(db)
                
                logger.info("User and profile created successfully for \(user.name)")
            }
        }
    }
    
    func getUserById(_ id: Int64) throws -> User? {
        return try dbQueue.read { db in
            try User.fetchOne(db, key: id)
        }
    }
    
    func updateUser(_ user: User) throws {
        try dbQueue.write { db in
            try user.update(db)
            logger.info("User updated: \(user.name)")
        }
    }
    
    func deleteUser(id: Int64) throws {
        try dbQueue.write { db in
            _ = try User.deleteOne(db, key: id)
            logger.info("User deleted with ID: \(id)")
        }
    }
}

// MARK: - Utilisation Exemple
func exampleUsage() {
    let databaseManager = DatabaseManager.shared
    
    do {
        try databaseManager.openDatabase()
        let dbQueue = try databaseManager.getDBQueue()
        
        // Création du DAO
        let userDao = UserDao(dbQueue: dbQueue)
        
        // Création d'un utilisateur
        let date = Date()
        let newUser = User(id: nil, name: "John Doe", email: "john@example.com", createdAt: date)
        let savedUser = try userDao.createUser(newUser)
        
        // Récupération des utilisateurs
        let users = try userDao.fetchUsers()
        print("Found \(users.count) users")
        
        // Exemple de jointure
        let usersWithProfile = try userDao.fetchUsersWithProfile()
        print("Found \(usersWithProfile.count) users with profile")
        
        // Créer un utilisateur avec un profil
        let anotherUser = User(id: nil, name: "Jane Smith", email: "jane@example.com", createdAt: Date())
        let profile = Profile(id: nil, userId: 0, bio: "Developer", avatarUrl: "https://example.com/avatar.jpg")
        try userDao.createUserWithProfile(user: anotherUser, profile: profile)
        
    } catch {
        print("Error: \(error)")
    }
}
