'use strict'
const mongoose = require('mongoose')

// Schema per le notifiche
const notificationSchema = new mongoose.Schema({
  type: { type: String, enum: ['email', 'sms'], required: true },
  recipient: { type: String, required: true },
  subject: String,
  status: { type: String, enum: ['sent', 'failed', 'pending'], default: 'pending' },
  payload: {
    user: {
      name: String,
      email: String,
      phone: String
    },
    movie: {
      title: String,
      format: String,
      schedule: String
    },
    cinema: {
      name: String,
      room: String,
      seats: String
    },
    totalAmount: Number,
    orderId: String,
    description: String
  },
  sentAt: { type: Date, default: null },
  error: { type: String, default: null }
}, { collection: 'notifications', timestamps: true })

const Notification = mongoose.model('Notification', notificationSchema)

const repository = (container) => {
  const sendEmail = (payload) => {
    return new Promise((resolve, reject) => {
      const {smtpSettings, smtpTransport, nodemailer} = container.cradle

      // Crea record di notifica
      const notification = new Notification({
        type: 'email',
        recipient: payload.user.email,
        subject: `Tickets for movie ${payload.movie.title}`,
        status: 'pending',
        payload: payload
      })

      // Salva la notifica prima di inviare
      notification.save()
        .then(() => {
          const transporter = nodemailer.createTransport(
            smtpTransport({
              service: smtpSettings.service,
              auth: {
                user: smtpSettings.user,
                pass: smtpSettings.pass
              }
            }))

          const mailOptions = {
            from: '"Do Not Reply, Cinemas Company 👥" <no-replay@cinemas.com>',
            to: `${payload.user.email}`,
            subject: `Tickets for movie ${payload.movie.title}`,
            html: `
                <h1>Tickets for ${payload.movie.title}</h1>

                <p>Cinema: ${payload.cinema.name}</p>
                <p>Room: ${payload.cinema.room}</p>
                <p>Seats: ${payload.cinema.seats}</p>

                <p>Description: ${payload.description}</p>

                <p>Total: ${payload.totalAmount}</p>
                <p>Order ID: ${payload.orderId}</p>

                <h3>Cinemas Microservice 2024, Enjoy your movie!</h3>
              `
          }

          transporter.sendMail(mailOptions, (err, info) => {
            if (err) {
              // Aggiorna lo status a failed
              notification.status = 'failed'
              notification.error = err.message
              notification.save()
              reject(new Error('An error occured sending an email, err:' + err))
            } else {
              // Aggiorna lo status a sent
              notification.status = 'sent'
              notification.sentAt = new Date()
              notification.save()
              transporter.close()
              resolve(info)
            }
          })
        })
        .catch(err => {
          reject(new Error('An error occured saving notification, err:' + err))
        })
    })
  }

  const sendSMS = (payload) => {
    return new Promise((resolve, reject) => {
      // Crea record di notifica
      const notification = new Notification({
        type: 'sms',
        recipient: payload.user.phone || payload.user.email,
        subject: 'SMS notification',
        status: 'pending',
        payload: payload
      })

      // Salva la notifica prima di inviare
      notification.save()
        .then(() => {
          // TODO: Implementare servizio SMS reale
          // Per ora simuliamo l'invio
          console.log(`SMS would be sent to ${payload.user.phone || payload.user.email}`)
          console.log(`Message: Tickets for ${payload.movie.title} at ${payload.cinema.name}`)
          
          // Simula successo
          notification.status = 'sent'
          notification.sentAt = new Date()
          notification.save()
          
          resolve({ message: 'SMS sent successfully (simulated)' })
        })
        .catch(err => {
          notification.status = 'failed'
          notification.error = err.message
          notification.save()
          reject(new Error('An error occured saving SMS notification, err:' + err))
        })
    })
  }

  const getNotifications = (filters = {}) => {
    return new Promise((resolve, reject) => {
      Notification.find(filters)
        .sort({ createdAt: -1 })
        .then(notifications => {
          resolve(notifications)
        })
        .catch(err => {
          reject(new Error('An error occured retrieving notifications, err:' + err))
        })
    })
  }

  const disconnect = () => {
    mongoose.connection.close()
  }

  return Object.create({
    sendSMS,
    sendEmail,
    getNotifications,
    disconnect
  })
}

const connect = (container) => {
  return new Promise((resolve, reject) => {
    if (!container) {
      reject(new Error('dependencies not supplied!'))
    }
    resolve(repository(container))
  })
}

module.exports = Object.assign({}, {connect})
