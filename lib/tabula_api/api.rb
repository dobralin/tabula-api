module TabulaApi
  class REST < Grape::API
    version 'v1', using: :header, vendor: 'tabula'
    format :json

    content_type :csv, 'text/csv'
    formatter :csv, lambda { |tables, env| tables.inject('') { |o, table| o += table.to_csv } }

    helpers do
      def job_executor
      end

      def is_valid_pdf?(path)
        File.open(path, 'r') { |f| f.read(4) } == '%PDF'
      end

      def get_document(uuid)
        doc = Models::Document.eager(:pages).first(uuid: uuid)
        error!('Not found', 404) if doc.nil?
        doc
      end

      def doc_to_h(doc)
        doc.values.merge(:pages => doc.pages.map(&:values))
      end

      ##
      # page: a Tabula::Page instance
      # coords: coordinates specification [{'top' => .., 'left' => ..., 'bottom' => ..., 'right' => ... }, ...]
      # extraction_method: original|spreadsheet|guess
      def extract_tables_from_page(page, coords, extraction_method)
        coords.map do |coord|
          area = page.get_area([coord['top'],
                               coord['left'],
                               coord['bottom'],
                               coord['right']])

          if extraction_method == 'spreadsheet' \
             || (extraction_method == 'guess' && area.is_tabular?)
            logger.info "Using extraction method: spreadsheet"
            (spreadsheets = area.spreadsheets).empty? ? Spreadsheet.empty(page) : spreadsheets.inject(&:+)
          else
            logger.info "Using extraction method: original"
            area.get_table
          end
        end
      end

      def autodetect_tables_from_page(page)

      end

      def logger
        REST.logger
      end
    end

    resource :documents do

      desc "Returns all the documents stored in Tabula"
      get do
        Models::Document.all
      end

      desc "Upload a PDF"
      params do
        requires :file,
                 type: Rack::Multipart::UploadedFile,
                 desc: 'PDF Document'
        optional :autodetect, type: Boolean, desc: "Should we attempt to auto-detect tables on the page?" #N.B. was "autodetect-tables in Tabula(-web)"
      end
      post do
        error!('Unsupported media type', 415) unless is_valid_pdf?(params[:file][:tempfile].path)

        doc = nil
        DB.transaction do
          doc = Models::Document.new_from_upload(params[:file])
        end
        doc
      end

      route_param :uuid, requirements: { uuid: /[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/ } do
        desc "An uploaded document"
        get do
          doc_to_h(get_document(params[:uuid]))
        end

        desc "Download the original PDF"
        get 'document' do
          doc = get_document(params[:uuid])
          content_type 'application/pdf'
          env['api.format'] = :binary
          File.open(doc.document_path).read
        end

        desc "Delete an uploaded document"
        delete do
          doc = get_document(params[:uuid])
          doc.destroy
        end

        desc "Autodetect tables in this document."
        get '/tables' do
          doc = get_document(params[:uuid])
          extractor = Tabula::Extraction::ObjectExtractor.new(doc.document_path)
          doc.pages_dataset.map do |p|
            if p.nil?
              []
            else
              page = extractor.extract_page(p.number)
              page.spreadsheet_areas.map{|rect| rect.dims(:left, :top, :width, :height)}
            end
          end
        end

        desc "Extract tables"
        params do
          requires :coords, type: Array
          optional :extraction_method, type: String, regexp: /^(original|spreadsheet|guess)$/
        end
        post 'tables' do
          doc = get_document(params[:uuid])
          extractor = Tabula::Extraction::ObjectExtractor.new(doc.document_path)
          extraction_method = params[:extraction_method] || 'guess'

          logger.info "Requested extraction method: #{extraction_method}"

          params[:coords]
            .sort_by { |c| c[:page] }
            .group_by { |c| c[:page] }
            .flat_map do |page_number, coords|

            page = extractor.extract_page(page_number)

            extract_tables_from_page(page, coords, extraction_method)

          end.flatten(1)
        end

        resource :pages do
          desc "Delete a page from a document"
          params do
            requires :number, type: Integer, desc: 'Page Number'
          end
          delete ':number', requirements: { number: /\d+/ } do
            doc = get_document(params[:uuid])
            page = doc.pages_dataset.where(number: params[:number]).first
            page.destroy
          end

          desc "Autodetect tables on this page"
          params do
            requires :number, type: Integer, desc: 'Page Number'
          end
          get ':number/tables' do
            doc = get_document(params[:uuid])
            p = doc.pages_dataset.where(number: params[:number]).first
            error!('Not found', 404) if p.nil?

            extractor = Tabula::Extraction::ObjectExtractor.new(doc.document_path)
            page = extractor.extract_page(p.number)

            page.spreadsheet_areas.map{|rect| rect.dims(:left, :top, :width, :height)}
          end

          desc 'Extract tables from this page'
          params do
            requires :coords, type: Array
            requires :number, type: Integer, desc: 'Page Number'
            optional :extraction_method, type: String, regexp: /^(original|spreadsheet|guess)$/
          end
          post ':number/tables' do
            doc = get_document(params[:uuid])
            p = doc.pages_dataset.where(number: params[:number]).first
            error!('Not found', 404) if p.nil?

            extractor = Tabula::Extraction::ObjectExtractor.new(doc.document_path)
            extraction_method = params[:extraction_method] || 'guess'

            page = extractor.extract_page(p.number)

            extract_tables_from_page(page, params[:coords], extraction_method)
          end
        end
      end
    end
  end
end
