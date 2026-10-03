export interface DocumentMetadata {
  original_size?: number | null

  archive_size?: number | null

  original_checksum?: string

  archived_checksum?: string

  original_mime_type?: string

  media_filename?: string

  original_filename?: string

  has_archive_version?: boolean

  lang?: string
}
