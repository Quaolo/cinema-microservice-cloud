'use strict'

const mongoose = require('mongoose')
const { getPosterUrl } = require('../s3')

// Schema per i film (basato sulla struttura reale del database)
const movieSchema = new mongoose.Schema({
  id: Number,
  title: String,
  year: Number,
  genres: [String],
  plot: String,
  directors: [String],
  cast: [String],
  imdb: {
    rating: Number,
    votes: Number,
    id: Number
  },
  runtime: Number,
  countries: [String],
  languages: [String],
  released: Date,
  awards: {
    wins: Number,
    nominations: Number,
    text: String
  },
  fullplot: String,
  writers: [String],
  type: String,
  tomatoes: {
    viewer: {
      rating: Number,
      numReviews: Number,
      meter: Number
    },
    lastUpdated: Date
  },
  lastupdated: String,
  num_mflix_comments: Number
}, { collection: 'movies' })

const Movie = mongoose.model('Movie', movieSchema)

const repository = () => {
  const getAllMovies = async () => {
    try {
      const movies = await Movie.find({}, {title: 1, id: 1})
      console.log('Found movies:', movies.length)
      
      // Aggiungi poster URL per ogni film
      for (let movie of movies) {
        movie.posterUrl = await getPosterUrl(movie.id)
      }
      
      return movies
    } catch (err) {
      console.error('Error fetching movies:', err)
      throw new Error('An error occured fetching all movies, err:' + err)
    }
  }

  const getMoviePremiers = async () => {
    try {
      const currentYear = new Date().getFullYear()
      const query = {
        year: {
          $gte: currentYear - 1,
          $lte: currentYear
        }
      }
      
      const movies = await Movie.find(query)
      console.log('Found premier movies:', movies.length)
      
      // Aggiungi poster URL per ogni film
      for (let movie of movies) {
        movie.posterUrl = await getPosterUrl(movie.id)
      }
      
      return movies
    } catch (err) {
      console.error('Error fetching premier movies:', err)
      throw new Error('An error occured fetching premier movies, err:' + err)
    }
  }

  const getMovieById = async (id) => {
    try {
      const movie = await Movie.findOne(
        { id: id },
        { _id: 0, id: 1, title: 1, year: 1, genres: 1, plot: 1 }
      )
      if (movie) {
        // Aggiungi poster dal bucket S3
        movie.posterUrl = await getPosterUrl(movie.id)
        console.log('Found movie by ID:', id, 'with poster URL:', movie.posterUrl ? 'Yes' : 'No')
      } else {
        console.log('Found movie by ID:', id, 'No')
      }
      return movie
    } catch (err) {
      console.error('Error fetching movie by ID:', err)
      throw new Error(`An error occured fetching a movie with id: ${id}, err: ${err}`)
    }
  }

  const disconnect = () => {
    mongoose.connection.close()
  }

  return Object.create({
    getAllMovies,
    getMoviePremiers,
    getMovieById,
    disconnect
  })
}

const connect = (connection) => {
  return new Promise((resolve, reject) => {
    // Non serve più la connessione, usiamo Mongoose direttamente
    resolve(repository())
  })
}

module.exports = Object.assign({}, {connect})

