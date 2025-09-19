# Cinema Microservices - AWS ECS Deployment

Un sistema di microservizi per la gestione di un cinema, deployato su AWS ECS con integrazione MongoDB Atlas e S3 per le immagini dei film.

## Panoramica

Questo progetto implementa un'architettura di microservizi completa per un sistema di gestione cinema, includendo:

- **API Gateway** - Punto di accesso unificato
- **Movies Service** - Gestione film e poster (con S3)
- **Cinema Catalog Service** - Gestione cinema e sale
- **Booking Service** - Prenotazioni e biglietti
- **Payment Service** - Elaborazione pagamenti (Stripe)
- **Notification Service** - Invio notifiche

## Caratteristiche Principali

### **Deploy Automatico su AWS**
- Script bash completo per deploy su ECS
- Creazione automatica di VPC, ALB, ECR, CloudWatch
- Configurazione Service Discovery per comunicazione tra servizi
- Gestione IAM roles e policies

### **Integrazione Database**
- **MongoDB Atlas** per persistenza dati
- **Mongoose** ODM per modellazione dati
- Collezioni: `movies`, `cinemas`, `bookings`, `tickets`, `notifications`, `payments`

### **Integrazione S3**
- Bucket S3 per poster dei film
- API endpoint per recupero URL poster
- Policy pubblica per accesso diretto alle immagini

### **Gestione Pagamenti**
- Logging completo delle transazioni
- API per visualizzazione storico pagamenti

### **Sistema Notifiche**
- Invio email e SMS (simulato)
- Logging notifiche in database
- API per visualizzazione storico notifiche

### **Monitoraggio e Logging**
- **CloudWatch Logs** per tutti i servizi
- Health checks automatici
- Metriche ECS e ALB

## Tecnologie Utilizzate

### **Backend**
- **Node.js** + **Express.js**
- **Mongoose** 
- **AWS SDK**

### **Infrastructure**
- **AWS ECS** (container orchestration)
- **AWS ECR** (container registry)
- **AWS ALB** (load balancing)
- **AWS VPC** (networking)
- **AWS S3** (object storage)
- **MongoDB Atlas** (database)

### **DevOps**
- **Docker** (containerization)
- **Bash Scripts** (automation)
- **AWS CLI** (deployment)

## Quick Start

### **Prerequisiti**
- AWS CLI configurato
- Docker installato
- Node.js 16+
- Account MongoDB Atlas

### **1. Clone del Repository**
```bash
git clone <repository-url>
cd cinema-microservice
```

### **2. Deploy Completo**
```bash
# Deploy completo su AWS
bash deploy-cinema-aws.sh
```

### **3. Deploy Solo Servizi (infrastruttura esistente)**
```bash
# Skip creazione infrastruttura
SKIP_INFRASTRUCTURE=true bash deploy-cinema-aws.sh
```

### **4. Cleanup Risorse**
```bash
# Rimuovi tutte le risorse AWS
CLEANUP=true bash deploy-cinema-aws.sh
```

## API Endpoints

### **Movies Service**
- `GET /movies` - Lista tutti i film
- `GET /movies/:id` - Dettagli film specifico
- `GET /movies/:id/poster` - URL poster del film

### **Cinema Catalog Service**
- `GET /cinemas` - Lista tutti i cinema
- `GET /cinemas?cityId=:cityId` - Cinema per città

### **Booking Service**
- `POST /bookings` - Crea nuova prenotazione
- `GET /bookings` - Lista prenotazioni
- `GET /bookings/:id` - Dettagli prenotazione

### **Payment Service**
- `POST /payments` - Processa pagamento
- `GET /payments` - Lista pagamenti
- `GET /payments/:id` - Dettagli pagamento

### **Notification Service**
- `GET /notifications` - Lista notifiche

# AWS

### **Porte Servizi**
- **API Gateway**: 8080
- **Movies Service**: 3000
- **Cinema Catalog**: 3001
- **Booking Service**: 3002
- **Payment Service**: 3003
- **Notification Service**: 3004

## Testing

### **Test API Gateway**
```bash
curl http://ALB-DNS/movies
curl http://ALB-DNS/cinemas
curl http://ALB-DNS/bookings
```

### **Test S3 Integration**
```bash
curl http://ALB-DNS/movies/1/poster
```

### **Test Health Checks**
```bash
curl http://ALB-DNS/health
```

## Monitoraggio

### **CloudWatch Logs**
- Log Group: `/ecs/{service-name}`
- Log Stream: `{task-id}/{container-name}`

## Sicurezza

### **IAM Roles**
- `ecsTaskExecutionRole` - Esecuzione container
- `ecsTaskRole` - Accesso servizi AWS
- Policy: `AmazonS3ReadOnlyAccess`

### **Network Security**
- VPC privata con subnet pubbliche/private
- Security Groups per controllo traffico
- ALB per terminazione SSL/TLS

### **Secrets Management**
- Credenziali MongoDB in variabili ambiente
- Chiavi Stripe in variabili ambiente
- Nessun secret hardcoded

## Troubleshooting

### **Servizi Non Partono**
```bash
# Controlla logs CloudWatch
aws logs get-log-events --log-group-name "/ecs/service-name"

# Controlla status ECS
aws ecs describe-services --cluster cinema-cluster --services service-name
```

### **502 Bad Gateway**
- Verifica health check path (`/` o `/health`)
- Controlla che i servizi siano in `RUNNING` state
- Verifica configurazione ALB target group

### **Database Connection Issues**
- Verifica `MONGODB_ATLAS_URI` con database name
- Controlla whitelist IP su MongoDB Atlas
- Verifica credenziali e permessi

### **S3 Access Denied**
- Verifica policy bucket S3
- Controlla Block Public Access settings
- Verifica IAM permissions per ECS tasks

## Scaling

### **Auto Scaling**
- ECS Service Auto Scaling configurato
- Target tracking per CPU/Memory
- Min/Max capacity configurabile

### **Load Balancing**
- ALB distribuisce traffico tra tasks
- Health checks automatici
- SSL termination

## Nota Importante sulla Sicurezza

**Questo è un progetto di dimostrazione e testing.** 

Per semplicità e scopi didattici, alcune configurazioni di sicurezza potrebbero non essere ottimali per un ambiente di produzione:

- **Chiavi e credenziali**: Alcuni file di configurazione contengono chiavi in chiaro per facilitare il testing
- **Secrets Management**: Non utilizza AWS Secrets Manager o sistemi di gestione segreti avanzati
- **Network Security**: Configurazioni di rete semplificate per scopi dimostrativi
- **IAM Policies**: Permessi potrebbero essere più permissivi del necessario

**Per un ambiente di produzione, si raccomanda di:**
- Utilizzare AWS Secrets Manager per tutte le credenziali
- Implementare principi di sicurezza "least privilege"
- Configurare WAF e protezioni avanzate
- Utilizzare certificati SSL/TLS appropriati
- Implementare monitoring e alerting avanzati

---
