import { DatePipe } from '@angular/common'
import { provideHttpClient, withInterceptorsFromDi } from '@angular/common/http'
import { provideHttpClientTesting } from '@angular/common/http/testing'
import { ComponentFixture, TestBed } from '@angular/core/testing'
import { By } from '@angular/platform-browser'
import { RouterTestingModule } from '@angular/router/testing'
import { NgxBootstrapIconsModule, allIcons } from 'ngx-bootstrap-icons'
import { DisplayField } from 'src/app/data/document'
import { TagComponent } from '../../common/tag/tag.component'
import { DocumentCardSmallComponent } from './document-card-small.component'

const doc = {
  id: 10,
  title: 'Document 10',
  tags: [1, 2, 3, 4, 5, 6, 7, 8],
  correspondent: 8,
  document_type: 10,
  storage_path: null,
  page_count: 12,
  notes: [
    {
      id: 11,
      note: 'This is some note content bananas',
    },
  ],
  content:
    'Cupcake ipsum dolor sit amet ice cream. Donut shortbread cheesecake caramels tiramisu pastry caramels chocolate bar. Tart tootsie roll muffin icing cotton candy topping sweet roll. Pie lollipop dragée sesame snaps donut tart pudding. Oat cake apple pie danish danish candy canes. Shortbread candy canes sesame snaps muffin tiramisu marshmallow chocolate bar halvah. Cake lemon drops candy apple pie carrot cake bonbon halvah pastry gummi bears. Sweet roll candy ice cream sesame snaps marzipan cookie ice cream. Cake cheesecake apple pie muffin candy toffee lollipop. Carrot cake oat cake cookie biscuit cupcake cake marshmallow. Sweet roll jujubes carrot cake cheesecake cake candy canes sweet roll gingerbread jelly beans. Apple pie sugar plum oat cake halvah cake. Pie oat cake chocolate cake cookie gingerbread marzipan. Lemon drops cheesecake lollipop danish marzipan candy.',
}

describe('DocumentCardSmallComponent', () => {
  let component: DocumentCardSmallComponent
  let fixture: ComponentFixture<DocumentCardSmallComponent>

  beforeEach(async () => {
    TestBed.configureTestingModule({
      imports: [
        RouterTestingModule,
        NgxBootstrapIconsModule.pick(allIcons),
        DocumentCardSmallComponent,
      ],
      providers: [
        DatePipe,
        provideHttpClient(withInterceptorsFromDi()),
        provideHttpClientTesting(),
      ],
    }).compileComponents()

    fixture = TestBed.createComponent(DocumentCardSmallComponent)
    component = fixture.componentInstance
    fixture.componentRef.setInput('document', Object.assign({}, doc))
    fixture.detectChanges()
    jest.useFakeTimers()
  })

  it('should show the card', () => {
    expect(component.show()).toBeTruthy()
    component.ngAfterViewInit()
    expect(component.show()).toBeTruthy()
  })

  it('should display page count', () => {
    expect(fixture.nativeElement.textContent).toContain('12 pages')
  })

  it('should show file sizes only when individually enabled', () => {
    fixture.componentRef.setInput('document', {
      ...doc,
      original_size: 1024,
      archive_size: 2 * 1024 * 1024,
    })
    fixture.detectChanges()
    expect(fixture.nativeElement.textContent).not.toContain(
      'Original file size'
    )
    expect(fixture.nativeElement.textContent).not.toContain('Archive file size')

    fixture.componentRef.setInput('displayFields', [DisplayField.ORIGINAL_SIZE])
    fixture.detectChanges()
    expect(fixture.nativeElement.textContent).toContain(
      'Original file size: 1 KB'
    )
    const originalIcon = fixture.nativeElement.querySelector(
      'i-bs[name="file-earmark-binary"]'
    )
    expect(originalIcon).not.toBeNull()
    expect(originalIcon.getAttribute('aria-hidden')).toBe('true')
    expect(
      originalIcon.parentElement.querySelector('.visually-hidden').textContent
    ).toBe('Original file size: ')
    expect(originalIcon.parentElement.querySelector('svg')).not.toBeNull()
    expect(fixture.nativeElement.textContent).not.toContain('Archive file size')

    fixture.componentRef.setInput('displayFields', [DisplayField.ARCHIVE_SIZE])
    fixture.detectChanges()
    expect(fixture.nativeElement.textContent).not.toContain(
      'Original file size'
    )
    expect(fixture.nativeElement.textContent).toContain(
      'Archive file size: 2.0 MB'
    )
    const archiveIcon = fixture.nativeElement.querySelector(
      'i-bs[name="file-earmark-pdf"]'
    )
    expect(archiveIcon).not.toBeNull()
    expect(archiveIcon.getAttribute('aria-hidden')).toBe('true')
    expect(
      archiveIcon.parentElement.querySelector('.visually-hidden').textContent
    ).toBe('Archive file size: ')
    expect(archiveIcon.parentElement.querySelector('svg')).not.toBeNull()
  })

  it('should distinguish zero bytes from an unavailable archive', () => {
    fixture.componentRef.setInput('document', {
      ...doc,
      original_size: 0,
      archive_size: null,
    })
    fixture.componentRef.setInput('displayFields', [
      DisplayField.ORIGINAL_SIZE,
      DisplayField.ARCHIVE_SIZE,
    ])
    fixture.detectChanges()
    expect(fixture.nativeElement.textContent).toContain(
      'Original file size: 0 bytes'
    )
    expect(fixture.nativeElement.textContent).toContain('Archive file size: —')
  })

  it('should show unavailable sizes when the properties are omitted', () => {
    fixture.componentRef.setInput('displayFields', [
      DisplayField.ORIGINAL_SIZE,
      DisplayField.ARCHIVE_SIZE,
    ])
    fixture.detectChanges()

    expect(fixture.nativeElement.textContent).toContain('Original file size: —')
    expect(fixture.nativeElement.textContent).toContain('Archive file size: —')
  })

  it('should lazy load the thumbnail', () => {
    const thumbnail: HTMLImageElement =
      fixture.nativeElement.querySelector('img.doc-img')
    expect(thumbnail.getAttribute('loading')).toEqual('lazy')
  })

  it('should prioritize the thumbnail when requested', () => {
    fixture.componentRef.setInput('priority', true)
    fixture.detectChanges()
    const thumbnail: HTMLImageElement =
      fixture.nativeElement.querySelector('img.doc-img')
    expect(thumbnail.getAttribute('loading')).toEqual('eager')
    expect(thumbnail.getAttribute('fetchpriority')).toEqual('high')
  })

  it('should display a document, limit tags to 5', () => {
    expect(fixture.nativeElement.textContent).toContain('Document 10')
    expect(
      fixture.debugElement.queryAll(By.directive(TagComponent))
    ).toHaveLength(5)
    fixture.componentRef.setInput('document', {
      ...component.document(),
      tags: [1, 2],
    })
    fixture.detectChanges()
    expect(
      fixture.debugElement.queryAll(By.directive(TagComponent))
    ).toHaveLength(2)
  })

  it('should increase limit tags to 6 if no notes', () => {
    fixture.componentRef.setInput('document', {
      ...component.document(),
      notes: [],
    })
    fixture.detectChanges()
    expect(
      fixture.debugElement.queryAll(By.directive(TagComponent))
    ).toHaveLength(6)
  })

  it('should clear hidden tag counter when tag count falls below the limit', () => {
    expect(component.moreTags).toEqual(3)

    fixture.componentRef.setInput('document', {
      ...component.document(),
      tags: [1, 2, 3, 4, 5, 6],
    })
    fixture.detectChanges()

    expect(component.moreTags).toBeNull()
    expect(fixture.nativeElement.textContent).not.toContain('+ 3')
  })

  it('should try to close the preview on mouse leave', () => {
    component.popupPreview = {
      close: jest.fn(),
    } as any
    component.mouseLeaveCard()
    expect(component.popupPreview.close).toHaveBeenCalled()
  })
})
