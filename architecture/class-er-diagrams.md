# 📊 System Diagrams

> Class Diagram and Entity Relationship Diagram for the Attendance Management System

## 1. Class Diagram

The class diagram shows the object-oriented design of the AMS system, including all entities, their attributes, methods, and relationships.

```mermaid
classDiagram
    direction TB
    
    %% ==================== USER DOMAIN ====================
    class User {
        +UUID id
        +String email
        -String passwordHash
        +String firstName
        +String lastName
        +String phone
        +String avatarUrl
        +UserRole role
        +Boolean isActive
        +Boolean emailVerified
        +DateTime lastLogin
        +DateTime createdAt
        +DateTime updatedAt
        +login(email, password) AuthToken
        +logout() void
        +changePassword(oldPwd, newPwd) Boolean
        +updateProfile(data) User
        +getInstitutes() List~Institute~
    }
    
    class Student {
        +UUID id
        +UUID userId
        +String studentCode
        +Date dateOfBirth
        +String guardianName
        +String guardianPhone
        +String guardianEmail
        +String address
        +JSON metadata
        +DateTime createdAt
        +DateTime updatedAt
        +getEnrolledInstitutes() List~Institute~
        +getEnrolledClasses() List~Class~
        +getNFCCards() List~NFCCard~
        +getAttendanceHistory(filters) List~Attendance~
        +getPaymentHistory(filters) List~Payment~
        +getOutstandingDues() List~Due~
    }
    
    class InstituteUser {
        +UUID id
        +UUID instituteId
        +UUID userId
        +InstituteRole role
        +Boolean isActive
        +DateTime createdAt
        +hasPermission(permission) Boolean
        +getInstitute() Institute
        +getUser() User
    }
    
    %% ==================== INSTITUTE DOMAIN ====================
    class Institute {
        +UUID id
        +String name
        +String code
        +String address
        +String phone
        +String email
        +String logoUrl
        +JSON settings
        +Boolean isActive
        +DateTime createdAt
        +DateTime updatedAt
        +getStudents() List~Student~
        +getClasses() List~Class~
        +getUsers() List~User~
        +getNFCCards() List~NFCCard~
        +getStatistics() InstituteStats
        +updateSettings(settings) Institute
    }
    
    class Class {
        +UUID id
        +UUID instituteId
        +String name
        +String code
        +String description
        +UUID instructorId
        +JSON schedule
        +String room
        +Integer capacity
        +ClassStatus status
        +Date startDate
        +Date endDate
        +DateTime createdAt
        +DateTime updatedAt
        +getStudents() List~Student~
        +getFees() List~ClassFee~
        +getAttendance(date) List~Attendance~
        +enrollStudent(studentId) StudentClass
        +removeStudent(studentId) void
        +isScheduledNow() Boolean
    }
    
    class ClassFee {
        +UUID id
        +UUID classId
        +String name
        +String description
        +Decimal amount
        +FeeFrequency frequency
        +Integer dueDay
        +Boolean isActive
        +DateTime createdAt
        +DateTime updatedAt
        +calculateDue(studentId, period) Decimal
        +getPayments(filters) List~Payment~
    }
    
    %% ==================== ENROLLMENT DOMAIN ====================
    class StudentInstitute {
        +UUID id
        +UUID studentId
        +UUID instituteId
        +String enrollmentNumber
        +Date enrollmentDate
        +EnrollmentStatus status
        +String notes
        +DateTime createdAt
        +activate() void
        +suspend() void
        +graduate() void
    }
    
    class StudentClass {
        +UUID id
        +UUID studentId
        +UUID classId
        +Date enrolledDate
        +StudentClassStatus status
        +String notes
        +DateTime createdAt
        +drop() void
        +complete() void
        +transfer(newClassId) StudentClass
    }
    
    %% ==================== NFC DOMAIN ====================
    class NFCCard {
        +UUID id
        +String cardUid
        +UUID studentId
        +UUID instituteId
        +CardStatus status
        +Date issuedDate
        +Date expiryDate
        +DateTime lastUsed
        +UUID issuedBy
        +String notes
        +DateTime createdAt
        +validate() ValidationResult
        +activate() void
        +deactivate() void
        +block(reason) void
        +unblock() void
        +replace(newCardUid) NFCCard
        +isExpired() Boolean
        +updateLastUsed() void
    }
    
    class CardTransaction {
        +UUID id
        +UUID nfcCardId
        +TransactionType transactionType
        +UUID performedBy
        +JSON details
        +DateTime createdAt
        +static log(cardId, type, userId, details) CardTransaction
    }
    
    %% ==================== ATTENDANCE DOMAIN ====================
    class Attendance {
        +UUID id
        +UUID studentId
        +UUID classId
        +UUID nfcCardId
        +UUID checkedBy
        +Date attendanceDate
        +DateTime checkInTime
        +DateTime checkOutTime
        +AttendanceStatus status
        +JSON deviceInfo
        +String notes
        +DateTime createdAt
        +static recordCheckIn(cardUid, classId, deviceInfo) Attendance
        +recordCheckOut() void
        +updateStatus(status, notes) void
        +isLate(classSchedule, threshold) Boolean
    }
    
    %% ==================== PAYMENT DOMAIN ====================
    class Payment {
        +UUID id
        +UUID studentId
        +UUID classId
        +UUID classFeeId
        +UUID receivedBy
        +Decimal amount
        +PaymentMethod paymentMethod
        +PaymentStatus status
        +String referenceNumber
        +Date paymentDate
        +Integer forMonth
        +Integer forYear
        +String notes
        +String receiptUrl
        +DateTime createdAt
        +static recordPayment(data) Payment
        +generateReceipt() String
        +refund(amount, reason) Payment
        +sendNotification() void
    }
    
    %% ==================== NOTIFICATION DOMAIN ====================
    class Notification {
        +UUID id
        +UUID userId
        +NotificationType type
        +NotificationChannel channel
        +String recipient
        +String subject
        +String content
        +NotificationStatus status
        +JSON metadata
        +Integer retryCount
        +DateTime sentAt
        +DateTime deliveredAt
        +String errorMessage
        +DateTime createdAt
        +send() void
        +retry() void
        +cancel() void
        +markDelivered() void
    }
    
    %% ==================== AUDIT DOMAIN ====================
    class AuditLog {
        +UUID id
        +UUID userId
        +String action
        +String entityType
        +UUID entityId
        +JSON oldValue
        +JSON newValue
        +String ipAddress
        +String userAgent
        +DateTime createdAt
        +static log(userId, action, entity, oldVal, newVal) AuditLog
    }
    
    %% ==================== ENUMERATIONS ====================
    class UserRole {
        <<enumeration>>
        SUPER_ADMIN
        INSTITUTE_ADMIN
        CARD_CHECKER
        STUDENT
    }
    
    class InstituteRole {
        <<enumeration>>
        ADMIN
        CARD_CHECKER
        INSTRUCTOR
        STAFF
    }
    
    class CardStatus {
        <<enumeration>>
        PENDING
        ACTIVE
        INACTIVE
        BLOCKED
        LOST
        EXPIRED
        REPLACED
    }
    
    class AttendanceStatus {
        <<enumeration>>
        PRESENT
        LATE
        EXCUSED
        ABSENT
    }
    
    class PaymentMethod {
        <<enumeration>>
        CASH
        CARD
        BANK_TRANSFER
        ONLINE
        OTHER
    }
    
    class FeeFrequency {
        <<enumeration>>
        ONE_TIME
        MONTHLY
        QUARTERLY
        YEARLY
    }
    
    %% ==================== RELATIONSHIPS ====================
    
    %% User relationships
    User "1" -- "0..1" Student : has profile
    User "1" -- "*" InstituteUser : belongs to
    User "1" -- "*" AuditLog : creates
    User "*" -- "1" UserRole : has
    
    %% Institute relationships
    Institute "1" -- "*" InstituteUser : has
    Institute "1" -- "*" Class : offers
    Institute "1" -- "*" NFCCard : issues
    Institute "1" -- "*" StudentInstitute : enrolls
    
    %% Student relationships
    Student "1" -- "*" StudentInstitute : enrolled in
    Student "1" -- "*" StudentClass : attends
    Student "1" -- "*" NFCCard : owns
    Student "1" -- "*" Attendance : has
    Student "1" -- "*" Payment : makes
    
    %% Class relationships
    Class "1" -- "*" StudentClass : has
    Class "1" -- "*" ClassFee : has
    Class "1" -- "*" Attendance : records
    Class "1" -- "*" Payment : receives
    Class "*" -- "1" User : instructed by
    
    %% NFC Card relationships
    NFCCard "1" -- "*" CardTransaction : logs
    NFCCard "1" -- "*" Attendance : used for
    
    %% Payment relationships
    Payment "*" -- "1" ClassFee : for
    Payment "1" -- "*" Notification : triggers
    
    %% Enumeration relationships
    InstituteUser "*" -- "1" InstituteRole : has
    NFCCard "*" -- "1" CardStatus : has
    Attendance "*" -- "1" AttendanceStatus : has
    Payment "*" -- "1" PaymentMethod : uses
    ClassFee "*" -- "1" FeeFrequency : has
```

## 2. Detailed Class Diagram (Core Entities)

```mermaid
classDiagram
    direction LR
    
    class User {
        +UUID id
        +String email
        -String passwordHash
        +String firstName
        +String lastName
        +String phone
        +UserRole role
        +Boolean isActive
        +DateTime lastLogin
    }
    
    class Student {
        +UUID id
        +UUID userId
        +String studentCode
        +Date dateOfBirth
        +String guardianName
        +String guardianPhone
        +String address
    }
    
    class Institute {
        +UUID id
        +String name
        +String code
        +String email
        +JSON settings
        +Boolean isActive
    }
    
    class NFCCard {
        +UUID id
        +String cardUid
        +UUID studentId
        +UUID instituteId
        +CardStatus status
        +Date expiryDate
    }
    
    class Class {
        +UUID id
        +UUID instituteId
        +String name
        +String code
        +JSON schedule
        +ClassStatus status
    }
    
    class Attendance {
        +UUID id
        +UUID studentId
        +UUID classId
        +UUID nfcCardId
        +Date attendanceDate
        +DateTime checkInTime
        +AttendanceStatus status
    }
    
    class Payment {
        +UUID id
        +UUID studentId
        +UUID classId
        +Decimal amount
        +PaymentMethod method
        +Date paymentDate
        +Integer forMonth
        +Integer forYear
    }
    
    User "1" -- "0..1" Student
    Student "1" -- "*" NFCCard
    NFCCard "*" -- "1" Institute
    Institute "1" -- "*" Class
    Student "1" -- "*" Attendance
    Class "1" -- "*" Attendance
    NFCCard "1" -- "*" Attendance
    Student "1" -- "*" Payment
    Class "1" -- "*" Payment
```

## 3. Entity Relationship Diagram (Chen Notation)

```mermaid
erDiagram
    %% ==================== CORE ENTITIES ====================
    
    USERS {
        uuid id PK "Primary Key"
        varchar email UK "Unique email address"
        varchar password_hash "Bcrypt hashed password"
        varchar first_name "User's first name"
        varchar last_name "User's last name"
        varchar phone "Contact phone"
        varchar avatar_url "Profile picture URL"
        enum role "super_admin|institute_admin|card_checker|student"
        boolean is_active "Account active status"
        boolean email_verified "Email verification status"
        timestamp last_login "Last login timestamp"
        timestamp created_at "Record creation time"
        timestamp updated_at "Last update time"
    }
    
    INSTITUTES {
        uuid id PK "Primary Key"
        varchar name "Institute name"
        varchar code UK "Unique institute code"
        text address "Physical address"
        varchar phone "Contact phone"
        varchar email "Contact email"
        varchar logo_url "Logo image URL"
        jsonb settings "Configuration settings"
        boolean is_active "Active status"
        timestamp created_at "Record creation time"
        timestamp updated_at "Last update time"
    }
    
    STUDENTS {
        uuid id PK "Primary Key"
        uuid user_id FK,UK "References users.id"
        varchar student_code UK "Unique student identifier"
        date date_of_birth "Student DOB"
        varchar guardian_name "Parent/Guardian name"
        varchar guardian_phone "Guardian contact"
        varchar guardian_email "Guardian email"
        text address "Student address"
        jsonb metadata "Additional info JSON"
        timestamp created_at "Record creation time"
        timestamp updated_at "Last update time"
    }
    
    CLASSES {
        uuid id PK "Primary Key"
        uuid institute_id FK "References institutes.id"
        varchar name "Class name"
        varchar code "Class code within institute"
        text description "Class description"
        uuid instructor_id FK "References users.id"
        jsonb schedule "Schedule JSON array"
        varchar room "Room/Location"
        integer capacity "Max students"
        enum status "active|inactive|completed|cancelled"
        date start_date "Class start date"
        date end_date "Class end date"
        timestamp created_at "Record creation time"
        timestamp updated_at "Last update time"
    }
    
    NFC_CARDS {
        uuid id PK "Primary Key"
        varchar card_uid UK "Physical card UID"
        uuid student_id FK "References students.id"
        uuid institute_id FK "References institutes.id"
        enum status "active|inactive|lost|expired|blocked"
        date issued_date "Card issue date"
        date expiry_date "Card expiration"
        timestamp last_used "Last card tap time"
        uuid issued_by FK "References users.id"
        text notes "Admin notes"
        timestamp created_at "Record creation time"
    }
    
    %% ==================== JUNCTION/BRIDGE TABLES ====================
    
    INSTITUTE_USERS {
        uuid id PK "Primary Key"
        uuid institute_id FK "References institutes.id"
        uuid user_id FK "References users.id"
        enum role "admin|card_checker|instructor|staff"
        boolean is_active "Membership active"
        timestamp created_at "Record creation time"
    }
    
    STUDENT_INSTITUTES {
        uuid id PK "Primary Key"
        uuid student_id FK "References students.id"
        uuid institute_id FK "References institutes.id"
        varchar enrollment_number UK "Institute enrollment number"
        date enrollment_date "Enrollment date"
        enum status "active|inactive|suspended|graduated"
        text notes "Enrollment notes"
        timestamp created_at "Record creation time"
    }
    
    STUDENT_CLASSES {
        uuid id PK "Primary Key"
        uuid student_id FK "References students.id"
        uuid class_id FK "References classes.id"
        date enrolled_date "Class enrollment date"
        enum status "enrolled|dropped|completed|transferred"
        text notes "Enrollment notes"
        timestamp created_at "Record creation time"
    }
    
    %% ==================== TRANSACTION TABLES ====================
    
    ATTENDANCE {
        uuid id PK "Primary Key"
        uuid student_id FK "References students.id"
        uuid class_id FK "References classes.id"
        uuid nfc_card_id FK "References nfc_cards.id"
        uuid checked_by FK "References users.id"
        date attendance_date "Attendance date"
        timestamp check_in_time "Check-in timestamp"
        timestamp check_out_time "Check-out timestamp"
        enum status "present|late|excused|absent"
        jsonb device_info "Device metadata"
        text notes "Attendance notes"
        timestamp created_at "Record creation time"
    }
    
    CLASS_FEES {
        uuid id PK "Primary Key"
        uuid class_id FK "References classes.id"
        varchar name "Fee name"
        text description "Fee description"
        decimal amount "Fee amount"
        enum frequency "one_time|monthly|quarterly|yearly"
        integer due_day "Day of month due (1-31)"
        boolean is_active "Fee active status"
        timestamp created_at "Record creation time"
        timestamp updated_at "Last update time"
    }
    
    PAYMENTS {
        uuid id PK "Primary Key"
        uuid student_id FK "References students.id"
        uuid class_id FK "References classes.id"
        uuid class_fee_id FK "References class_fees.id"
        uuid received_by FK "References users.id"
        decimal amount "Payment amount"
        enum payment_method "cash|card|bank_transfer|online|other"
        enum status "pending|completed|failed|refunded"
        varchar reference_number "Receipt number"
        date payment_date "Payment date"
        integer for_month "Payment period month"
        integer for_year "Payment period year"
        text notes "Payment notes"
        varchar receipt_url "Receipt file URL"
        timestamp created_at "Record creation time"
    }
    
    %% ==================== AUDIT/LOG TABLES ====================
    
    CARD_TRANSACTIONS {
        uuid id PK "Primary Key"
        uuid nfc_card_id FK "References nfc_cards.id"
        enum transaction_type "issued|activated|deactivated|blocked|unblocked|replaced|expired"
        uuid performed_by FK "References users.id"
        jsonb details "Transaction details JSON"
        timestamp created_at "Record creation time"
    }
    
    NOTIFICATIONS {
        uuid id PK "Primary Key"
        uuid user_id FK "References users.id"
        enum type "payment_confirmation|payment_reminder|attendance|general|alert"
        enum channel "sms|email|push|in_app"
        varchar recipient "Phone or email"
        varchar subject "Notification subject"
        text content "Notification body"
        enum status "pending|sent|delivered|failed|cancelled"
        jsonb metadata "Additional metadata"
        integer retry_count "Delivery attempts"
        timestamp sent_at "Send timestamp"
        timestamp delivered_at "Delivery timestamp"
        text error_message "Error if failed"
        timestamp created_at "Record creation time"
    }
    
    AUDIT_LOGS {
        uuid id PK "Primary Key"
        uuid user_id FK "References users.id"
        varchar action "Action performed"
        varchar entity_type "Entity type modified"
        uuid entity_id "Entity ID modified"
        jsonb old_value "Previous state"
        jsonb new_value "New state"
        inet ip_address "Client IP"
        text user_agent "Browser/client info"
        timestamp created_at "Record creation time"
    }
    
    %% ==================== RELATIONSHIPS ====================
    
    %% User to Student (1:1)
    USERS ||--o| STUDENTS : "has profile"
    
    %% User to Institute (M:N via INSTITUTE_USERS)
    USERS ||--o{ INSTITUTE_USERS : "belongs to"
    INSTITUTES ||--o{ INSTITUTE_USERS : "has"
    
    %% Student to Institute (M:N via STUDENT_INSTITUTES)
    STUDENTS ||--o{ STUDENT_INSTITUTES : "enrolled in"
    INSTITUTES ||--o{ STUDENT_INSTITUTES : "enrolls"
    
    %% Institute to Class (1:N)
    INSTITUTES ||--o{ CLASSES : "offers"
    
    %% Class Instructor
    USERS ||--o{ CLASSES : "instructs"
    
    %% Student to Class (M:N via STUDENT_CLASSES)
    STUDENTS ||--o{ STUDENT_CLASSES : "attends"
    CLASSES ||--o{ STUDENT_CLASSES : "has"
    
    %% NFC Cards
    STUDENTS ||--o{ NFC_CARDS : "owns"
    INSTITUTES ||--o{ NFC_CARDS : "issues"
    USERS ||--o{ NFC_CARDS : "issued by"
    
    %% Card Transactions
    NFC_CARDS ||--o{ CARD_TRANSACTIONS : "logs"
    USERS ||--o{ CARD_TRANSACTIONS : "performed by"
    
    %% Class Fees
    CLASSES ||--o{ CLASS_FEES : "has"
    
    %% Attendance
    STUDENTS ||--o{ ATTENDANCE : "has"
    CLASSES ||--o{ ATTENDANCE : "records"
    NFC_CARDS ||--o{ ATTENDANCE : "used for"
    USERS ||--o{ ATTENDANCE : "checked by"
    
    %% Payments
    STUDENTS ||--o{ PAYMENTS : "makes"
    CLASSES ||--o{ PAYMENTS : "receives"
    CLASS_FEES ||--o{ PAYMENTS : "for"
    USERS ||--o{ PAYMENTS : "received by"
    
    %% Notifications
    USERS ||--o{ NOTIFICATIONS : "receives"
    
    %% Audit Logs
    USERS ||--o{ AUDIT_LOGS : "creates"
```

## 4. Simplified ER Diagram (Core Business Entities)

```mermaid
erDiagram
    INSTITUTE ||--o{ CLASS : offers
    INSTITUTE ||--o{ STUDENT_ENROLLMENT : has
    INSTITUTE ||--o{ NFC_CARD : issues
    
    STUDENT ||--o{ STUDENT_ENROLLMENT : "enrolled in"
    STUDENT ||--o{ CLASS_ENROLLMENT : attends
    STUDENT ||--o{ NFC_CARD : owns
    STUDENT ||--o{ ATTENDANCE : has
    STUDENT ||--o{ PAYMENT : makes
    
    CLASS ||--o{ CLASS_ENROLLMENT : has
    CLASS ||--o{ CLASS_FEE : charges
    CLASS ||--o{ ATTENDANCE : records
    CLASS ||--o{ PAYMENT : receives
    
    NFC_CARD ||--o{ ATTENDANCE : "used for"
    
    CLASS_FEE ||--o{ PAYMENT : for
    
    INSTITUTE {
        uuid id PK
        string name
        string code UK
        boolean is_active
    }
    
    STUDENT {
        uuid id PK
        string student_code UK
        string guardian_phone
    }
    
    CLASS {
        uuid id PK
        uuid institute_id FK
        string name
        string code
    }
    
    NFC_CARD {
        uuid id PK
        string card_uid UK
        uuid student_id FK
        uuid institute_id FK
        enum status
    }
    
    STUDENT_ENROLLMENT {
        uuid id PK
        uuid student_id FK
        uuid institute_id FK
        string enrollment_number UK
        enum status
    }
    
    CLASS_ENROLLMENT {
        uuid id PK
        uuid student_id FK
        uuid class_id FK
        enum status
    }
    
    ATTENDANCE {
        uuid id PK
        uuid student_id FK
        uuid class_id FK
        uuid nfc_card_id FK
        date attendance_date
        enum status
    }
    
    CLASS_FEE {
        uuid id PK
        uuid class_id FK
        decimal amount
        enum frequency
    }
    
    PAYMENT {
        uuid id PK
        uuid student_id FK
        uuid class_id FK
        uuid class_fee_id FK
        decimal amount
        date payment_date
    }
```

## 5. Domain Model Diagram

```mermaid
graph TB
    subgraph "Identity & Access"
        User[👤 User]
        Auth[🔐 Authentication]
        Role[📋 Role]
    end
    
    subgraph "Organization"
        Institute[🏫 Institute]
        Class[📚 Class]
        ClassFee[💵 Class Fee]
    end
    
    subgraph "Student Management"
        Student[👨‍🎓 Student]
        Enrollment[📝 Enrollment]
        NFCCard[💳 NFC Card]
    end
    
    subgraph "Operations"
        Attendance[✅ Attendance]
        Payment[💰 Payment]
    end
    
    subgraph "Communication"
        Notification[📧 Notification]
        SMS[📱 SMS]
        Email[✉️ Email]
    end
    
    subgraph "Audit"
        AuditLog[📋 Audit Log]
        CardTransaction[🔄 Card Transaction]
    end
    
    User --> Auth
    User --> Role
    User --> Student
    
    Institute --> Class
    Class --> ClassFee
    
    Student --> Enrollment
    Enrollment --> Institute
    Student --> NFCCard
    NFCCard --> Institute
    
    Student --> Attendance
    Class --> Attendance
    NFCCard --> Attendance
    
    Student --> Payment
    Class --> Payment
    ClassFee --> Payment
    
    Payment --> Notification
    Notification --> SMS
    Notification --> Email
    
    User --> AuditLog
    NFCCard --> CardTransaction
```

## 6. Cardinality Summary

| Relationship | Type | Description |
|--------------|------|-------------|
| User → Student | 1:0..1 | A user may optionally be a student |
| Institute → Class | 1:N | One institute has many classes |
| Institute → NFC Card | 1:N | One institute issues many cards |
| Student → NFC Card | 1:N | One student can have multiple cards (one per institute) |
| Student → Institute | M:N | Students can enroll in multiple institutes |
| Student → Class | M:N | Students can enroll in multiple classes |
| Class → Class Fee | 1:N | One class can have multiple fee types |
| Student + Class → Attendance | Many records per combination |
| Student + Class + Fee → Payment | Many records per combination |

---

**Related Documentation:**
- [Database Design](./database-design.md) - SQL Schema definitions
- [System Architecture](./system-architecture.md) - Overall system design
- [API Design](./api-design.md) - RESTful API endpoints

