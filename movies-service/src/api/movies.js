'use strict'
const status = require('http-status')

module.exports = (app, options) => {
  const {repo} = options


  app.get('/movies', (req, res, next) => {
    // Se c'è un parametro id nella query, cerca un film specifico
    if (req.query.id) {
      repo.getMovieById(req.query.id).then(movie => {
        res.status(status.OK).json(movie)
      }).catch(next)
    } else {
      // Altrimenti restituisci tutti i film
      repo.getAllMovies().then(movies => {
        res.status(status.OK).json(movies)
      }).catch(next)
    }
  })

  app.get('/movies/premieres', (req, res, next) => {
    repo.getMoviePremiers().then(movies => {
      res.status(status.OK).json(movies)
    }).catch(next)
  })

  app.get('/movies/:id', (req, res, next) => {
    repo.getMovieById(req.params.id).then(movie => {
      res.status(status.OK).json(movie)
    }).catch(next)
  })

  app.get('/movies/:id/poster', async (req, res, next) => {
    try {
      const movie = await repo.getMovieById(req.params.id)
      if (!movie || !movie.posterUrl) {
        return res.status(status.NOT_FOUND).json({ error: 'Poster not found' })
      }
      res.status(status.OK).json({ id: movie.id, posterUrl: movie.posterUrl })
    } catch (err) {
      next(err)
    }
  })
}
