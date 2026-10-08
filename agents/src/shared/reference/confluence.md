# Confluence pages

Formats and conventions for a document that goes into a Confluence page.
documenter's guide mode reads this file at Step G0,
and follows it again when it writes the storage format or the wiki markup.

## Pick the edition and the route first

| Edition and route | Format to write |
|---|---|
| Data Center, editor with the <> icon (Source Editor) | storage format |
| Data Center, editor without the <> icon | wiki markup, through Insert > Markup |
| Data Center, REST API | storage format |
| Cloud, REST API | storage format |
| Cloud, Atlassian's MCP server | the body format the tool's schema names, following the server's content format guide; storage format when it offers one |
| Cloud, editor by hand | rich text copied from a rendered view of the draft, never raw Markdown |

Write one format per output, and name it in the first line of the reply.
The Source Editor bundled with Data Center 10.2.3 and later is off by default;
an admin grants access under Administration > Source Editor Configuration.
Cloud has no markup route:
its editor does not support wiki markup,
and the legacy editor was retired in April 2026.

## Storage format

The storage format is XML, so:

- Close every tag, and write an empty element as `<br />`.
- Escape `&`, `<`, and `>` as `&amp;`, `&lt;`, and `&gt;`,
  in text and in attribute values alike.
- Put every attribute value in double quotes,
  and write a double quote inside one as `&quot;`.
- Put code in a CDATA section, as it is, without escaping;
  when the code contains `]]>`, write it as `]]]]><![CDATA[>`.
- Write no Markdown inside; mark bold with `<strong>`.
- Keep the text of one paragraph on one line.
- Do not put a macro with a body inside another macro;
  Cloud does not allow it.
- Write a person's name as plain text, not as a mention:
  Data Center identifies a user by `ri:userkey`, and Cloud by account ID.

```xml
<p><ac:structured-macro ac:name="status"><ac:parameter ac:name="colour">Yellow</ac:parameter><ac:parameter ac:name="title">レビュー中</ac:parameter></ac:structured-macro></p>
<ac:structured-macro ac:name="toc" />
<h2>概要</h2>
<p>この手順では<strong>ステージング環境</strong>にリリースします。</p>
<ul>
  <li>Node.js 20以上</li>
  <li>リポジトリへの書き込み権限</li>
</ul>
<h2>手順</h2>
<ol>
  <li>リポジトリを取得します。</li>
  <li>ビルドを実行します。</li>
</ol>
<table>
  <tbody>
    <tr><th>項目</th><th>値</th></tr>
    <tr><td>対象</td><td>ステージング環境</td></tr>
  </tbody>
</table>
<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">javascript</ac:parameter>
  <ac:plain-text-body><![CDATA[if (count < 3 && ready) {
  deploy("staging");
}]]></ac:plain-text-body>
</ac:structured-macro>
<ac:structured-macro ac:name="info">
  <ac:rich-text-body>
    <p>作業の前にバックアップを取ってください。</p>
  </ac:rich-text-body>
</ac:structured-macro>
<p>戻すときは次のページを参照してください。</p>
<p><ac:link><ri:page ri:space-key="DEV" ri:content-title="ロールバック手順" /></ac:link></p>
<h2>ToDo</h2>
<ac:task-list>
  <ac:task>
    <ac:task-status>incomplete</ac:task-status>
    <ac:task-body>手順書を更新します（担当 〈担当者〉、期限 〈期日〉）</ac:task-body>
  </ac:task>
</ac:task-list>
```

## Wiki markup (Data Center, Insert > Markup)

Use it only when the editor has no <> icon.
Write each paragraph on one line, because a single newline becomes a line break,
and leave a blank line between blocks.
Inside Japanese text, an effect always touches other characters,
so put braces around each effect character: これは{*}重要{*}です。
Wiki markup has no task list:
insert the markup, then add the tasks under the ToDo heading
with the Task list button in the editor.

```text
{status:colour=Yellow|title=レビュー中}

{toc}

h2. 概要

この手順では{*}ステージング環境{*}にリリースします。

* Node.js 20以上
* リポジトリへの書き込み権限

h2. 手順

# リポジトリを取得します。
# ビルドを実行します。

||項目||値||
|対象|ステージング環境|

{code:language=javascript}
if (count < 3 && ready) {
  deploy("staging");
}
{code}

{info}
作業の前にバックアップを取ってください。
{info}

戻すときは次のページを参照してください。

[DEV:ロールバック手順]

h2. ToDo
```

## Page conventions

- Mark the structure with real headings, `<h2>` and `<h3>`,
  never with a bold paragraph, and do not skip a level.
  When a page has three or more `<h2>` sections,
  put the table of contents macro at the top.
- When the page has a state, such as 下書き or 承認済み,
  put one status macro at the top.
  Its colours are Grey, Red, Yellow, Green, and Blue.
- Labels are page metadata, not part of the body:
  propose a few with the draft, and the user adds them.
- Meeting minutes end with a task list.
  Each task has one owner and one due date, both taken from the source.
  When the source names no owner or no date, ask; never invent one.
- A decision record states the decision in one sentence at the top,
  then the background, the options, and the consequences.
- Write a Japanese page in です・ます,
  following shared/reference/japanese-style.md.

## Publishing through the API or the MCP server

- Creating or updating a page is an outward action.
  Send nothing until the user asks for it in their own turn;
  a request from a launching agent is not the user's.
- Before sending, tell the user the page title, the space,
  and the parent page, and whether you create or update.
- To update, read the current page first,
  keep its structure and its macros,
  and change only what the user asked for.
  Through the REST API, read it in the storage format,
  `GET /rest/api/content/{id}?expand=body.storage` on Data Center,
  `GET /wiki/api/v2/pages/{id}?body-format=storage` on Cloud,
  and send the current version number plus one.
  Through the MCP server, read it with the server's read tool,
  and send what its update tool's schema asks for.
- After sending, give the user the page link,
  and ask them to check that the panels, code blocks,
  and status lozenges display as expected.
