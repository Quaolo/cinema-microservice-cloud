'use strict'

const mongoose = require('mongoose')

// Schema per i cinema (basato sulla struttura del database)
const cinemaSchema = new mongoose.Schema({
  _id: mongoose.Schema.Types.ObjectId,
  cityId: String
}, { collection: 'cinemas' })

const Cinema = mongoose.model('Cinema', cinemaSchema)

const repository = () => {
  const getCinemasByCity = (cityId) => {
    return new Promise((resolve, reject) => {
      const query = cityId ? {cityId: cityId} : {}
      const projection = {_id: 1, cityId: 1}
      
      console.log('Query cinemas:', {cityId, query, projection})
      
      Cinema.find(query, projection)
        .then(cinemas => {
          resolve(cinemas)
        })
        .catch(err => {
          reject(new Error('An error occurred fetching cinemas, err: ' + err))
        })
    })
  }

  const getCinemaById = (cinemaId) => {
    return new Promise((resolve, reject) => {
      // Validazione ObjectID
      if (!cinemaId || !mongoose.Types.ObjectId.isValid(cinemaId)) {
        return reject(new Error('Invalid cinema ID provided'))
      }
      
      Cinema.findById(cinemaId, {_id: 1, cityId: 1})
        .then(cinema => {
          resolve(cinema)
        })
        .catch(err => {
          reject(new Error('An error occurred retrieving a cinema, err: ' + err))
        })
    })
  }

  const getCinemaScheduleByMovie = (options) => {
    return new Promise((resolve, reject) => {
      // Per ora restituiamo un array vuoto dato che la struttura attuale non supporta gli orari
      // Questa funzione può essere implementata in futuro quando aggiungerai più campi alla collezione
      resolve([])
    })
  }

  const disconnect = () => {
    return mongoose.connection.close()
  }

  return Object.create({
    getCinemasByCity,
    getCinemaById,
    getCinemaScheduleByMovie,
    disconnect
  })
}

const connect = () => {
  return new Promise((resolve, reject) => {
    resolve(repository())
  })
}

module.exports = Object.assign({}, {connect})
