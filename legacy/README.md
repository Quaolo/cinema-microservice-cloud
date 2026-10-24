# Legacy: deploy originale con Docker Swarm

Questa cartella conserva gli script del progetto di partenza ("cinema microservice" di
Cristian Ramirez, 2017), da cui è nato questo repository. Prima della migrazione ad AWS ECS
i servizi venivano eseguiti su un cluster **Docker Swarm** creato in locale con
**docker-machine** e VirtualBox.

I file sono mantenuti solo come riferimento storico: **non sono più usati** né dal deploy su
AWS (`deploy-cinema-aws.sh`) né dallo stack locale (`docker-compose.yml`), e richiedono
strumenti ormai dismessi (docker-machine, boot2docker).

## Come funzionava

1. `_docker_setup/setup-swarm.sh` creava tre macchine virtuali VirtualBox (`manager1`,
   `worker1`, `worker2`), inizializzava lo Swarm e vi univa i worker
   (`automation/create-machines.sh` crea solo le macchine).
2. `_docker_setup/create-images.sh` costruiva l'immagine di ogni servizio
   (`<servizio>/create-image.sh`) e la pubblicava su Docker Hub come `crizstian/<servizio>`.
3. `_docker_setup/start-services.sh` (o `automation/start_all_microservices.sh`) avviava ogni
   servizio con `<servizio>/start-service.sh`, cioè `docker service create` con:
   - una porta pubblicata sullo Swarm (movies 3000, catalog 3001, booking 3002,
     payment 3003, notification 3004);
   - un'etichetta `apiRoute` (`/movies`, `/cinemas`, `/booking`, `/payment`, `/notification`).
4. L'API gateway (`api-gateway/start-service.sh`) girava su ogni nodo e scopriva le rotte
   interrogando l'API di Docker (`api-gateway/src/docker/docker.js`, libreria `dockerode`):
   per ogni servizio leggeva l'etichetta `apiRoute` e la porta pubblicata.
5. `_docker_setup/reset.sh` rimuoveva servizi e immagini.

## Cosa lo ha sostituito

| Swarm (qui) | Versione attuale |
|---|---|
| docker-machine + VirtualBox | AWS ECS Fargate (`deploy-cinema-aws.sh`) o Docker Compose in locale |
| Docker Hub `crizstian/*` | Amazon ECR / build locale |
| Scoperta rotte via API Docker (`docker.js`) | Tabella rotte statica (`api-gateway/src/config/config.js`) + AWS Cloud Map |
| Porte booking 3002 / payment 3003 | Porte booking 3003 / payment 3002 |

L'assegnazione delle porte e i percorsi al singolare (`/booking`, `/payment`,
`/notification`) vengono da questa configurazione: spiegano alcune differenze ancora presenti
tra README, gateway e servizi.

## Struttura

I file mantengono la posizione relativa che avevano nel progetto originale:

```
legacy/
├── _docker_setup/            creazione Swarm, build/push immagini, avvio e reset dei servizi
├── automation/               versione semplificata degli stessi script
├── api-gateway/
│   ├── start-service.sh      avvio del gateway su ogni nodo
│   └── src/docker/           scoperta delle rotte tramite API Docker
└── <servizio>/
    ├── create-image.sh       build dell'immagine
    └── start-service.sh      docker service create con etichetta apiRoute
```

Dopo lo spostamento, gli script costruiscono le immagini dalle cartelle dei servizi nella
radice del repository (`../../<servizio>`) e leggono da lì gli eventuali file `env`.
`api-gateway/start-service.sh` contiene ancora un percorso assoluto della macchina
dell'autore originale (`/Users/Cramirez/...`), lasciato invariato.
