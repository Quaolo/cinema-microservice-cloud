'use strict'
const mongoose = require('mongoose')

// Schema per le prenotazioni
const bookingSchema = new mongoose.Schema({
  city: String,
  userType: String,
  totalAmount: Number,
  cinema: {
    name: String,
    room: String,
    seats: String
  },
  movie: {
    title: String,
    format: String,
    schedule: String
  },
  createdAt: { type: Date, default: Date.now },
  status: { type: String, default: 'pending' }
}, { collection: 'bookings' })

// Schema per i biglietti
const ticketSchema = new mongoose.Schema({
  orderId: String,
  description: String,
  city: String,
  userType: String,
  totalAmount: Number,
  cinema: {
    name: String,
    room: String,
    seats: String
  },
  movie: {
    title: String,
    format: String,
    schedule: String
  },
  createdAt: { type: Date, default: Date.now },
  status: { type: String, default: 'issued' }
}, { collection: 'tickets' })

const Booking = mongoose.model('Booking', bookingSchema)
const Ticket = mongoose.model('Ticket', ticketSchema)

const repository = (container) => {
  const makeBooking = (user, booking) => {
    return new Promise((resolve, reject) => {
      const payload = {
        city: booking.city,
        userType: (user.membership) ? 'loyal' : 'normal',
        totalAmount: booking.totalAmount,
        cinema: {
          name: booking.cinema,
          room: booking.cinemaRoom,
          seats: booking.seats.toString()
        },
        movie: {
          title: booking.movie.title,
          format: booking.movie.format,
          schedule: booking.schedule
        }
      }

      const newBooking = new Booking(payload)
      newBooking.save()
        .then(savedBooking => {
          resolve(savedBooking.toObject())
        })
        .catch(err => {
          reject(new Error('An error occuered registring a user booking, err:' + err))
        })
    })
  }

  const generateTicket = (paid, booking) => {
    return new Promise((resolve, reject) => {
      const payload = Object.assign({}, booking, {orderId: paid.charge.id, description: paid.description})
      const newTicket = new Ticket(payload)
      newTicket.save()
        .then(savedTicket => {
          resolve(savedTicket.toObject())
        })
        .catch(err => {
          reject(new Error('an error occured registring a ticket, err:' + err))
        })
    })
  }

  const getOrderById = (orderId) => {
    return new Promise((resolve, reject) => {
      // Validazione ObjectID
      if (!orderId || !mongoose.Types.ObjectId.isValid(orderId)) {
        return reject(new Error('Invalid order ID provided'))
      }
      
      Booking.findById(orderId)
        .then(order => {
          resolve(order)
        })
        .catch(err => {
          reject(new Error('An error occuered retrieving a order, err: ' + err))
        })
    })
  }

  const getBookings = () => {
    return new Promise((resolve, reject) => {
      Booking.find({})
        .then(bookings => {
          resolve(bookings)
        })
        .catch(err => {
          reject(new Error('An error occurred fetching bookings, err: ' + err))
        })
    })
  }

  const disconnect = () => {
    mongoose.connection.close()
  }

  return Object.create({
    makeBooking,
    getOrderById,
    generateTicket,
    getBookings,
    disconnect
  })
}

const connect = (container) => {
  return new Promise((resolve, reject) => {
    if (!container) {
      reject(new Error('container not supplied!'))
    }
    resolve(repository(container))
  })
}

module.exports = Object.assign({}, {connect})
