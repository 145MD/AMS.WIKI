# 🏗️ System Architecture

> Comprehensive architectural design for the Attendance Management System

## 1. Architecture Overview

The AMS follows a **microservices-inspired modular monolith** architecture, designed to be scalable, maintainable, and secure. This approach provides the benefits of service separation while maintaining operational simplicity for the MVP phase.

### 1.1 High-Level Architecture Diagram

```mermaid
graph TB
    subgraph "Frontend Layer"
        direction LR
        PWA[📱 PWA<br/>Card Checker App]
        AdminUI[🖥️ Admin Portal<br/>React SPA]
        StudentUI[👨‍🎓 Student Portal<br/>React SPA]
    end

    subgraph "CDN & Load Balancer"
        CDN[☁️ CDN]
        LB[⚖️ Load Balancer]
    end

    subgraph "API Layer"
        APIGateway[🔐 API Gateway<br/>Authentication & Rate Limiting]
    end

    subgraph "Application Services"
        direction TB
        subgraph "Core Services"
            AuthSvc[🔑 Authentication<br/>Service]
            InstituteSvc[🏫 Institute<br/>Service]
            StudentSvc[👤 Student<br/>Service]
            ClassSvc[📚 Class<br/>Service]
        end
        
        subgraph "Business Services"
            NFCSvc[💳 NFC Card<br/>Service]
            AttendanceSvc[✅ Attendance<br/>Service]
            PaymentSvc[💰 Payment<br/>Service]
        end
        
        subgraph "Support Services"
            NotificationSvc[📧 Notification<br/>Service]
            ReportSvc[📊 Reporting<br/>Service]
            AuditSvc[📝 Audit<br/>Service]
        end
    end

    subgraph "Data Layer"
        PrimaryDB[(🐘 PostgreSQL<br/>Primary DB)]
        ReadReplica[(📖 PostgreSQL<br/>Read Replica)]
        CacheLayer[(⚡ Redis<br/>Cache & Sessions)]
        FileStorage[📁 Object Storage<br/>S3/MinIO]
    end

    subgraph "External Integrations"
        SMSProvider[📱 SMS Gateway<br/>Twilio/Local Provider]
        EmailProvider[📧 Email Service<br/>SendGrid/SES]
        NFCProvider[💳 NFC Hardware<br/>Integration]
    end

    subgraph "DevOps & Monitoring"
        Logs[📋 Centralized<br/>Logging]
        Metrics[📈 Metrics &<br/>Monitoring]
        Alerts[🚨 Alerting<br/>System]
    end

    PWA --> CDN
    AdminUI --> CDN
    StudentUI --> CDN
    CDN --> LB
    LB --> APIGateway

    APIGateway --> AuthSvc
    APIGateway --> InstituteSvc
    APIGateway --> StudentSvc
    APIGateway --> ClassSvc
    APIGateway --> NFCSvc
    APIGateway --> AttendanceSvc
    APIGateway --> PaymentSvc
    APIGateway --> ReportSvc

    AuthSvc --> PrimaryDB
    AuthSvc --> CacheLayer
    InstituteSvc --> PrimaryDB
    StudentSvc --> PrimaryDB
    ClassSvc --> PrimaryDB
    NFCSvc --> PrimaryDB
    AttendanceSvc --> PrimaryDB
    PaymentSvc --> PrimaryDB
    ReportSvc --> ReadReplica
    AuditSvc --> PrimaryDB

    PaymentSvc --> NotificationSvc
    AttendanceSvc --> NotificationSvc
    NotificationSvc --> SMSProvider
    NotificationSvc --> EmailProvider

    AuthSvc --> Logs
    InstituteSvc --> Logs
    StudentSvc --> Logs
    Logs --> Metrics
    Metrics --> Alerts
```

## 2. Component Architecture

### 2.1 Frontend Applications

```mermaid
graph LR
    subgraph "PWA - Card Checker App"
        PWAShell[App Shell]
        NFCReader[NFC Reader Module]
        AttendanceUI[Attendance UI]
        PaymentUI[Payment UI]
        OfflineSync[Offline Sync]
        ServiceWorker[Service Worker]
    end

    subgraph "Admin Portal"
        Dashboard[Dashboard]
        InstMgmt[Institute Management]
        UserMgmt[User Management]
        ClassMgmt[Class Management]
        Reports[Reports & Analytics]
        Settings[Settings]
    end

    subgraph "Student Portal"
        StudentDash[Dashboard]
        AttendanceHistory[Attendance History]
        PaymentHistory[Payment History]
        Profile[Profile Management]
    end
```

#### 2.1.1 PWA (Progressive Web App) Features

| Feature | Description | Technology |
|---------|-------------|------------|
| **Offline Support** | Works without internet connection | Service Workers, IndexedDB |
| **NFC Reading** | Read NFC cards via Web NFC API | Web NFC API |
| **Push Notifications** | Real-time updates | Web Push API |
| **Installable** | Add to home screen | Web App Manifest |
| **Background Sync** | Sync data when online | Background Sync API |

### 2.2 Backend Service Architecture

```mermaid
graph TB
    subgraph "API Gateway Layer"
        Gateway[API Gateway]
        RateLimiter[Rate Limiter]
        AuthMiddleware[Auth Middleware]
        RequestValidator[Request Validator]
    end

    subgraph "Authentication Service"
        JWTHandler[JWT Handler]
        SessionMgr[Session Manager]
        RoleMgr[Role Manager]
        PasswordHandler[Password Handler]
    end

    subgraph "Institute Service"
        InstCRUD[Institute CRUD]
        InstConfig[Configuration]
        InstUsers[User Assignment]
    end

    subgraph "Student Service"
        StudentCRUD[Student CRUD]
        Enrollment[Enrollment Manager]
        StudentSearch[Search & Filter]
    end

    subgraph "Class Service"
        ClassCRUD[Class CRUD]
        Schedule[Schedule Manager]
        ClassEnrollment[Class Enrollment]
    end

    subgraph "NFC Card Service"
        CardProvisioning[Card Provisioning]
        CardValidation[Card Validation]
        CardLinking[Student Linking]
        CardStatus[Status Management]
    end

    subgraph "Attendance Service"
        AttendanceRecord[Attendance Recording]
        AttendanceQuery[Query & Reports]
        RealTimeTracking[Real-time Tracking]
    end

    subgraph "Payment Service"
        FeeManagement[Fee Management]
        PaymentRecording[Payment Recording]
        PaymentHistory[Payment History]
        DueCalculation[Due Calculation]
    end

    subgraph "Notification Service"
        SMSHandler[SMS Handler]
        EmailHandler[Email Handler]
        TemplateEngine[Template Engine]
        NotificationQueue[Message Queue]
    end

    Gateway --> RateLimiter
    RateLimiter --> AuthMiddleware
    AuthMiddleware --> RequestValidator
    
    RequestValidator --> JWTHandler
    RequestValidator --> InstCRUD
    RequestValidator --> StudentCRUD
    RequestValidator --> ClassCRUD
    RequestValidator --> CardProvisioning
    RequestValidator --> AttendanceRecord
    RequestValidator --> FeeManagement
```

## 3. Data Flow Architecture

### 3.1 Student Registration Flow

```mermaid
sequenceDiagram
    participant S as Student
    participant A as Admin Portal
    participant API as API Gateway
    participant IS as Institute Service
    participant SS as Student Service
    participant NFC as NFC Card Service
    participant NS as Notification Service
    participant DB as Database

    S->>A: Submit Registration
    A->>API: POST /api/students/register
    API->>API: Validate & Authenticate
    API->>IS: Verify Institute
    IS->>DB: Check Institute Exists
    DB-->>IS: Institute Data
    IS-->>API: Institute Verified
    
    API->>SS: Create Student
    SS->>DB: Insert Student Record
    DB-->>SS: Student Created
    SS-->>API: Student ID
    
    API->>NFC: Provision NFC Card
    NFC->>NFC: Generate Unique Card ID
    NFC->>DB: Create Card Record
    NFC->>DB: Link Card to Student & Institute
    DB-->>NFC: Card Linked
    NFC-->>API: Card Details
    
    API->>NS: Send Welcome Notification
    NS->>NS: Queue SMS & Email
    NS-->>API: Notification Queued
    
    API-->>A: Registration Complete
    A-->>S: Display Success + Card Info
```

### 3.2 Attendance Check-in Flow

```mermaid
sequenceDiagram
    participant St as Student
    participant NFC as NFC Card
    participant PWA as PWA App
    participant API as API Gateway
    participant CS as Card Service
    participant AS as Attendance Service
    participant DB as Database
    participant Cache as Redis Cache

    St->>NFC: Tap Card
    NFC->>PWA: Card Data (UID)
    PWA->>PWA: Read Card via Web NFC
    
    PWA->>API: POST /api/attendance/checkin
    Note over PWA,API: {cardUID, classId, timestamp}
    
    API->>Cache: Check Card in Cache
    alt Card in Cache
        Cache-->>API: Card Data (cached)
    else Card not in Cache
        API->>CS: Validate Card
        CS->>DB: Query Card Details
        DB-->>CS: Card + Student Data
        CS->>Cache: Cache Card Data
        CS-->>API: Validated Card Data
    end
    
    API->>AS: Record Attendance
    AS->>AS: Validate Class Schedule
    AS->>AS: Check Duplicate Entry
    AS->>DB: Insert Attendance Record
    DB-->>AS: Record Created
    AS-->>API: Attendance Confirmed
    
    API-->>PWA: Success Response
    PWA-->>St: ✅ Check-in Confirmed
    Note over PWA: Display Student Name & Photo
```

### 3.3 Payment Processing Flow

```mermaid
sequenceDiagram
    participant CC as Card Checker
    participant PWA as PWA App
    participant API as API Gateway
    participant PS as Payment Service
    participant NS as Notification Service
    participant DB as Database
    participant SMS as SMS Gateway
    participant Email as Email Service

    CC->>PWA: Initiate Payment
    PWA->>API: GET /api/payments/dues/{studentId}/{classId}
    API->>PS: Get Outstanding Dues
    PS->>DB: Query Payment Status
    DB-->>PS: Due Amount
    PS-->>API: Due Details
    API-->>PWA: Display Dues
    
    CC->>PWA: Record Payment
    PWA->>API: POST /api/payments/record
    Note over PWA,API: {studentId, classId, amount, method}
    
    API->>PS: Process Payment
    PS->>PS: Validate Amount
    PS->>DB: Create Payment Record
    PS->>DB: Update Payment Status
    DB-->>PS: Payment Recorded
    
    PS->>NS: Trigger Notifications
    
    par Send SMS
        NS->>SMS: Send Payment SMS
        SMS-->>NS: SMS Sent
    and Send Email
        NS->>Email: Send Payment Email
        Email-->>NS: Email Sent
    end
    
    NS-->>PS: Notifications Sent
    PS-->>API: Payment Complete
    API-->>PWA: Success + Receipt
    PWA-->>CC: Display Confirmation
```

## 4. Deployment Architecture

### 4.1 Cloud Deployment Diagram

```mermaid
graph TB
    subgraph "Internet"
        Users[👥 Users]
        Mobile[📱 Mobile Devices]
    end

    subgraph "Edge Layer"
        CloudFlare[☁️ CloudFlare CDN]
        WAF[🛡️ Web Application Firewall]
    end

    subgraph "Cloud Provider (AWS/GCP/Azure)"
        subgraph "Public Subnet"
            ALB[⚖️ Application Load Balancer]
        end
        
        subgraph "Private Subnet - App Tier"
            AppServer1[🖥️ App Server 1]
            AppServer2[🖥️ App Server 2]
            AppServerN[🖥️ App Server N]
        end
        
        subgraph "Private Subnet - Data Tier"
            RDSPrimary[(🐘 RDS Primary)]
            RDSReplica[(📖 RDS Replica)]
            ElastiCache[(⚡ ElastiCache Redis)]
            S3[📁 S3 Bucket]
        end
        
        subgraph "Management"
            Bastion[🔐 Bastion Host]
            CloudWatch[📊 CloudWatch]
            SNS[📧 SNS]
        end
    end

    subgraph "External Services"
        Twilio[📱 Twilio SMS]
        SendGrid[📧 SendGrid]
    end

    Users --> CloudFlare
    Mobile --> CloudFlare
    CloudFlare --> WAF
    WAF --> ALB
    ALB --> AppServer1
    ALB --> AppServer2
    ALB --> AppServerN
    
    AppServer1 --> RDSPrimary
    AppServer2 --> RDSPrimary
    AppServerN --> RDSPrimary
    
    AppServer1 --> ElastiCache
    AppServer2 --> ElastiCache
    AppServerN --> ElastiCache
    
    RDSPrimary --> RDSReplica
    
    AppServer1 --> S3
    AppServer1 --> Twilio
    AppServer1 --> SendGrid
    
    AppServer1 --> CloudWatch
    CloudWatch --> SNS
```

### 4.2 Container Architecture (Docker/Kubernetes)

```mermaid
graph TB
    subgraph "Kubernetes Cluster"
        subgraph "Ingress"
            Nginx[Nginx Ingress Controller]
        end
        
        subgraph "Application Namespace"
            subgraph "Frontend Pods"
                AdminPod[Admin Portal Pod]
                StudentPod[Student Portal Pod]
                PWAPod[PWA Pod]
            end
            
            subgraph "Backend Pods"
                APIPod1[API Pod 1]
                APIPod2[API Pod 2]
                APIPod3[API Pod 3]
            end
            
            subgraph "Worker Pods"
                NotificationWorker[Notification Worker]
                ReportWorker[Report Worker]
            end
        end
        
        subgraph "Data Namespace"
            PostgresPod[(PostgreSQL StatefulSet)]
            RedisPod[(Redis StatefulSet)]
        end
        
        subgraph "Monitoring Namespace"
            Prometheus[Prometheus]
            Grafana[Grafana]
            Loki[Loki]
        end
    end

    Nginx --> AdminPod
    Nginx --> StudentPod
    Nginx --> PWAPod
    Nginx --> APIPod1
    Nginx --> APIPod2
    Nginx --> APIPod3
    
    APIPod1 --> PostgresPod
    APIPod1 --> RedisPod
    APIPod2 --> PostgresPod
    APIPod2 --> RedisPod
    APIPod3 --> PostgresPod
    APIPod3 --> RedisPod
    
    NotificationWorker --> RedisPod
    ReportWorker --> PostgresPod
```

## 5. Security Architecture

### 5.1 Security Layers

```mermaid
graph TB
    subgraph "Perimeter Security"
        WAF[Web Application Firewall]
        DDoS[DDoS Protection]
        SSL[SSL/TLS Termination]
    end
    
    subgraph "Application Security"
        Auth[Authentication Layer]
        RBAC[Role-Based Access Control]
        InputVal[Input Validation]
        RateLimit[Rate Limiting]
    end
    
    subgraph "Data Security"
        Encryption[Data Encryption at Rest]
        TLS[Data Encryption in Transit]
        Masking[Data Masking]
        Backup[Encrypted Backups]
    end
    
    subgraph "Infrastructure Security"
        VPC[VPC Isolation]
        SG[Security Groups]
        IAM[IAM Policies]
        Audit[Audit Logging]
    end
    
    WAF --> Auth
    DDoS --> Auth
    SSL --> Auth
    
    Auth --> Encryption
    RBAC --> Encryption
    InputVal --> Encryption
    RateLimit --> Encryption
    
    Encryption --> VPC
    TLS --> VPC
    Masking --> VPC
    Backup --> VPC
```

### 5.2 Authentication Flow

```mermaid
sequenceDiagram
    participant U as User
    participant C as Client App
    participant AG as API Gateway
    participant AS as Auth Service
    participant DB as Database
    participant R as Redis

    U->>C: Enter Credentials
    C->>AG: POST /auth/login
    AG->>AS: Validate Credentials
    AS->>DB: Query User
    DB-->>AS: User Data
    AS->>AS: Verify Password (bcrypt)
    
    alt Valid Credentials
        AS->>AS: Generate JWT Token
        AS->>AS: Generate Refresh Token
        AS->>R: Store Session
        AS-->>AG: Tokens + User Info
        AG-->>C: 200 OK + Tokens
        C->>C: Store Tokens Securely
        C-->>U: Login Success
    else Invalid Credentials
        AS-->>AG: Authentication Failed
        AG-->>C: 401 Unauthorized
        C-->>U: Login Failed
    end
```

## 6. Integration Architecture

### 6.1 External Service Integration

```mermaid
graph LR
    subgraph "AMS Core"
        NS[Notification Service]
        PS[Payment Service]
        RS[Reporting Service]
    end
    
    subgraph "SMS Providers"
        Twilio[Twilio]
        LocalSMS[Local SMS Provider]
    end
    
    subgraph "Email Providers"
        SendGrid[SendGrid]
        SES[AWS SES]
    end
    
    subgraph "Analytics"
        GA[Google Analytics]
        Mixpanel[Mixpanel]
    end
    
    NS -->|Primary| Twilio
    NS -->|Fallback| LocalSMS
    NS -->|Primary| SendGrid
    NS -->|Fallback| SES
    
    RS --> GA
    RS --> Mixpanel
```

## 7. Scalability Considerations

### 7.1 Horizontal Scaling Strategy

| Component | Scaling Strategy | Trigger |
|-----------|------------------|---------|
| API Servers | Auto-scaling group | CPU > 70% |
| Database | Read replicas | Read load > threshold |
| Cache | Redis Cluster | Memory > 80% |
| Workers | Queue-based scaling | Queue depth |

### 7.2 Performance Targets

| Metric | Target | Maximum |
|--------|--------|---------|
| API Response Time | < 200ms | 500ms |
| NFC Tap to Confirm | < 1s | 2s |
| Concurrent Users | 1000 | 5000 |
| Transactions/second | 100 | 500 |

## 8. Technology Stack Summary

| Layer | Technology | Justification |
|-------|------------|---------------|
| Frontend | React + TypeScript | Type safety, ecosystem |
| PWA | Workbox + Web NFC | Offline support, NFC |
| Backend | Node.js + Express | Performance, ecosystem |
| Database | PostgreSQL | ACID, JSON support |
| Cache | Redis | Speed, pub/sub |
| Queue | Bull (Redis) | Reliable job processing |
| Auth | JWT + bcrypt | Stateless, secure |
| Deployment | Docker + K8s | Scalability, portability |

---

**Next:** [Database Design](./database-design.md) | [API Design](./api-design.md)

