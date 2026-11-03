import React from 'react'
import { Datagrid, TextField } from 'react-admin'
import { List, Title } from '../common'

const genreAlbumsRoute = (id) => {
  const filter = encodeURIComponent(JSON.stringify({ genre_id: [id] }))
  return `/album?filter=${filter}&order=ASC&sort=name`
}

const GenreList = (props) => (
  <List
    {...props}
    title={<Title subTitle="Genres" />}
    sort={{ field: 'name', order: 'ASC' }}
    exporter={false}
    bulkActionButtons={false}
  >
    <Datagrid rowClick={genreAlbumsRoute}>
      <TextField source="name" />
    </Datagrid>
  </List>
)

export default GenreList
