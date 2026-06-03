# Schema design reference

Methodology for designing a data or API schema.
Used by the coding skill's schema mode.
The goal is a schema that states its constraints explicitly
and can evolve without breaking its consumers.

## Choose the form

Pick by where the schema lives and who reads it:

- Database DDL (SQL CREATE TABLE): the source of truth is a relational store.
- JSON Schema: validating JSON over the wire, or a config file.
- Language types (dataclass, interface, struct, record): an in-process contract.
- API contract (OpenAPI, protobuf): a cross-service interface.

When more than one applies, the persistence layer (DDL) is usually the
authority and the others derive from it.

## Model the data

- Entities and their fields, each with a concrete type.
- Relationships and their cardinality (one to one, one to many, many to many).
- Identity: every entity has a stable key.
- Required vs optional: decide per field.
  Optional must be a deliberate choice, not a default.
  A field that is sometimes absent is nullable; say so.

## Express constraints in the schema

State these where the form allows it, not only in code:

- Keys: a primary key, and foreign keys for relationships.
- Uniqueness: which fields or combinations must be unique.
- Nullability: which fields may be null or absent.
- Domain: ranges, lengths, enumerations, formats.
- Referential integrity: what happens to children when a parent is removed.

## Normalization vs denormalization

Normalize by default: each fact lives in one place,
so it cannot disagree with itself.
Denormalize only as a deliberate, documented trade for a measured read cost,
and state how the duplicated data is kept consistent.

## Plan for evolution

A schema changes. Design so a change does not break existing consumers:

- Prefer additive changes (a new optional field)
  over breaking ones (a renamed or removed field, a narrowed type).
- For a breaking change, version the schema or provide a migration.
- For stored data, every schema change needs a migration plan.

## Validate at the boundary

Enforce the schema where external data enters,
using the language's validation library
(see the per-language reference: Pydantic, Zod, Jakarta Bean Validation).
Inside trusted code, the typed schema is assumed valid.
